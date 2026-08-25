//! Headless walkthrough of the sheet lifecycle (interaction-model
//! rev C) — the window, in a terminal, with time under your control.
//!
//! ```text
//! cargo run -p companion-core --example demo
//! ```
//!
//! Pages hold ink and sealed chips. Sealing is by gesture (`seal`,
//! `paste-seal`), never by detection; chips render as their mechanical
//! excerpt and nothing else — there is no reveal command, at any
//! privilege. One pausable countdown per page; the ledger keeps what
//! happened, in metadata, never what was written. `conceal` dry-runs
//! the v3 conceal request without a byte leaving the machine; `send` is
//! the real thing.

use std::io::{BufRead, Write as _};
use std::time::Duration;

use companion_core::{
    DestinationClass, ManualClock, Segment, Sheet, SheetId, SheetStore, Tab, TabId,
};
use companion_credentials::default_credential_store;
use companion_pasteboard::{ContentKind, MemoryPasteboard, Pasteboard, WriteOptions};
use companion_transport::UreqTransport;
use ots_client::{Api, BasicAuth, Client, ConcealPayload, NoAuth, share_link, snap_ttl};

const DEMO_SERVER: &str = "https://eu.onetimesecret.com";

/// Server-allowed TTLs a real client would learn from the config
/// endpoint at connection-test time (docs/spec/05).
const ALLOWED_TTLS: &[u64] = &[300, 1800, 3600, 14_400, 28_800, 86_400, 259_200, 604_800];

/// Keychain (or dev-store) accounts `login`/`logout` manage. Two items
/// rather than one, so neither half is ever a full credential alone.
const CRED_ACCOUNT_KEY: &str = "demo-api-key";
const CRED_ACCOUNT_SECRET: &str = "demo-api-secret";

fn main() {
    // No core dumps while secrets are held; text buffers are mlocked
    // besides.
    companion_core::harden_process();
    let clock = ManualClock::new();
    let mut store = SheetStore::new(clock.clone());
    let mut pasteboard = MemoryPasteboard::new();
    let mut current: Option<SheetId> = None;

    println!("╭──────────────────────────────────────────────────────────────╮");
    println!("│  Sheet demo — the core crate, headless (rev C)               │");
    println!("│  Ink is visible. Chips are sealed by gesture, never read.    │");
    println!("╰──────────────────────────────────────────────────────────────╯");
    println!("Type `help` for commands. Time only moves when you `tick` it.\n");

    let stdin = std::io::stdin();
    loop {
        let title = current.and_then(|id| tab_holding(&store, id)).map_or_else(
            || "no page".to_string(),
            |tab| tab.label(store.local_offset_seconds()),
        );
        print!("companionapp:{title}> ");
        std::io::stdout().flush().ok();
        let Some(Ok(line)) = stdin.lock().lines().next() else {
            break;
        };
        let line = line.trim();
        let (cmd, rest) = line.split_once(' ').unwrap_or((line, ""));
        // Commands that need a current page resolve it once, here.
        match cmd {
            "" => {}
            "help" | "?" => help(),
            "new" | "n" => match store.new_tab() {
                Ok((_, id)) => {
                    current = Some(id);
                    println!("a new page, default rung. the countdown is running.");
                }
                Err(e) => println!("refused: {e}"),
            },
            "go" | "g" => match nth_sheet(&store, rest) {
                Some(id) => current = Some(id),
                None => println!("no such page"),
            },
            "tabs" | "ls" | "l" => render(&store, current),
            "ink" | "i" => {
                if let Some(id) = page(&mut current, &store) {
                    ink(&mut store, id, rest);
                }
            }
            "seal" | "s" => {
                if let Some(id) = page(&mut current, &store) {
                    seal(&mut store, id, rest);
                }
            }
            "put" => put(&mut pasteboard, rest),
            "paste-seal" | "pv" => {
                if let Some(id) = page(&mut current, &store) {
                    paste_seal(&mut store, &mut pasteboard, id);
                }
            }
            "image" => {
                if let Some(id) = page(&mut current, &store) {
                    image(&mut store, id);
                }
            }
            "rm-chip" => {
                if let Some(id) = page(&mut current, &store) {
                    rm_chip(&mut store, id, rest);
                }
            }
            "copy" | "c" => {
                if let Some(id) = page(&mut current, &store) {
                    copy_out(&mut store, &mut pasteboard, id, rest);
                }
            }
            "clear" => clear(&mut pasteboard),
            "rung" => {
                if let Some(id) = page(&mut current, &store) {
                    cycle_rung(&mut store, id);
                }
            }
            "pause" => {
                if let Some(id) = page(&mut current, &store) {
                    pause(&mut store, id);
                }
            }
            "close" => {
                if let Some(tab) = current.and_then(|id| slot(&store, id)) {
                    store.close_tab(tab);
                    current = store.sheets().next().map(Sheet::id);
                    println!("closed. the ledger keeps the fact, not the page.");
                } else {
                    println!("no page");
                }
            }
            "ledger" => ledger(&store),
            "clear-ledger" => {
                store.clear_ledger();
                println!("the ledger is empty.");
            }
            "tick" | "t" => tick(&mut store, &clock, rest, &mut current),
            "conceal" => {
                if let Some(id) = page(&mut current, &store) {
                    conceal(&mut store, id, rest);
                }
            }
            "send" => {
                if let Some(id) = page(&mut current, &store) {
                    send(&mut store, id, rest);
                }
            }
            "login" => login(rest),
            "logout" => logout(),
            "quit" | "q" | "exit" => break,
            other => println!("unknown command `{other}` — try `help`"),
        }
    }
    let held = store.len();
    if held > 0 {
        println!(
            "exit is total amnesia: {held} page(s) zeroized — ledger included. nothing persists."
        );
    }
}

fn help() {
    println!(
        "\
  new                a new page, default rung (⌥⌘N)
  go <n>             jump to page n in tab order (⌘n)
  tabs               the tab strip and the current page
  ink <text>         type a line of visible ink onto the page
  seal <text>        the ⌘↩ gesture: seal text into an opaque chip
  put <text>         put text on the demo clipboard (another app's copy)
  paste-seal         the ⇧⌘V gesture: seal whatever the clipboard holds
  image              seal a pretend screenshot (metadata-only chip)
  rm-chip <n>        ⌫ on chip n: removes it whole, bytes zeroized
  copy <n>           copy chip n back out (marked ConcealedType + transient)
  clear              clear-after-copy: only if the clipboard is still ours
  rung               click the countdown label: one rung shorter, clock reset
  pause              double-click the tab: hold 1h, top up to 24h, release
  close              close the page; the ledger keeps the fact
  ledger             ⌘0, what happened, in metadata only
  clear-ledger       throw the whole ledger away
  tick <2h|30m|5s>   advance the clock; due pages expire silently
  conceal <n|page>   dry-run the v3 conceal request — nothing is sent
  send <n|page>      the real thing: a live POST to {DEMO_SERVER}
                     (guest route, or authenticated after `login`)
  login <key> <secret>   store API credentials (Keychain on macOS)
  logout                 remove stored credentials
  quit"
    );
}

/// The current page, fixed up first if it expired out from under the
/// prompt. `None` (with a nudge) when no pages exist.
fn page(current: &mut Option<SheetId>, store: &SheetStore<ManualClock>) -> Option<SheetId> {
    if current.and_then(|id| store.sheet(id)).is_none() {
        *current = store.sheets().next().map(Sheet::id);
    }
    if current.is_none() {
        println!("no page — `new` makes one");
    }
    *current
}

fn nth_sheet(store: &SheetStore<ManualClock>, arg: &str) -> Option<SheetId> {
    let n: usize = arg.trim().parse().ok()?;
    store.sheets().nth(n.checked_sub(1)?).map(Sheet::id)
}

fn nth_chip(store: &SheetStore<ManualClock>, page: SheetId, arg: &str) -> Option<u64> {
    let n: usize = arg.trim().parse().ok()?;
    store
        .sheet(page)?
        .chips()
        .nth(n.checked_sub(1)?)
        .map(|c| c.id().raw())
}

fn ink(store: &mut SheetStore<ManualClock>, page: SheetId, text: &str) {
    if text.is_empty() {
        println!("usage: ink <text>");
        return;
    }
    let mut segments: Vec<Segment> = store
        .sheet(page)
        .map(|s| s.segments().to_vec())
        .unwrap_or_default();
    segments.push(Segment::Ink(format!("{text}\n")));
    if store.sync_document(page, segments) {
        println!("ink. (you see it; it was never sealed.)");
    }
}

fn seal(store: &mut SheetStore<ManualClock>, page: SheetId, text: &str) {
    if text.is_empty() {
        println!("usage: seal <text>");
        return;
    }
    match store.seal_text(page, text) {
        Ok(chip) => {
            let mut segments: Vec<Segment> = store
                .sheet(page)
                .map(|s| s.segments().to_vec())
                .unwrap_or_default();
            segments.push(Segment::Chip(chip));
            store.sync_document(page, segments);
            let sheet = store.sheet(page).expect("just sealed");
            let sealed = sheet.chip(chip).expect("just sealed");
            println!(
                "sealed: [ {} · {} ] — bytes core-side, never rendered again.",
                sealed.excerpt(),
                sealed.size_label()
            );
        }
        Err(e) => println!("refused: {e}"),
    }
}

fn put(pb: &mut MemoryPasteboard, text: &str) {
    if text.is_empty() {
        println!("usage: put <text>");
        return;
    }
    pb.put_external(
        companion_pasteboard::PasteboardContent::Text(text.to_string()),
        false,
    );
    println!("on the demo clipboard, as another app would leave it.");
}

fn paste_seal(store: &mut SheetStore<ManualClock>, pb: &mut MemoryPasteboard, page: SheetId) {
    // The ⇧⌘V route: the core reads the board itself; consent is the
    // gesture, and what arrives is never parsed or classified.
    let Some(item) = pb.read() else {
        println!("the clipboard is empty");
        return;
    };
    let sealed = match item.content {
        companion_pasteboard::PasteboardContent::Text(text) => store.seal_text(page, &text),
        companion_pasteboard::PasteboardContent::Image(bytes) => store.seal_image(page, bytes),
    };
    match sealed {
        Ok(chip) => {
            let mut segments: Vec<Segment> = store
                .sheet(page)
                .map(|s| s.segments().to_vec())
                .unwrap_or_default();
            segments.push(Segment::Chip(chip));
            store.sync_document(page, segments);
            let sheet = store.sheet(page).expect("page exists");
            let sealed = sheet.chip(chip).expect("just sealed");
            println!(
                "sealed from the clipboard: [ {} · {} ]",
                sealed.excerpt(),
                sealed.size_label()
            );
        }
        Err(e) => println!("refused: {e}"),
    }
}

fn image(store: &mut SheetStore<ManualClock>, page: SheetId) {
    // A pretend 212 KB screenshot with a PNG header — the face shows
    // metadata only, read without opening the contents.
    let mut bytes = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
    bytes.resize(212 * 1024, 0);
    match store.seal_image(page, bytes) {
        Ok(chip) => {
            let mut segments: Vec<Segment> = store
                .sheet(page)
                .map(|s| s.segments().to_vec())
                .unwrap_or_default();
            segments.push(Segment::Chip(chip));
            store.sync_document(page, segments);
            println!("sealed. the chip shows kind and size, nothing else.");
        }
        Err(e) => println!("refused: {e}"),
    }
}

fn rm_chip(store: &mut SheetStore<ManualClock>, page: SheetId, arg: &str) {
    match nth_chip(store, page, arg) {
        Some(raw) => {
            store.delete_chip(companion_core::ChipId::from_raw(raw));
            println!("gone whole; bytes zeroized. undo never un-seals.");
        }
        None => println!("no such chip"),
    }
}

fn render(store: &SheetStore<ManualClock>, current: Option<SheetId>) {
    if store.has_no_tabs() {
        println!("(no tabs — the system working, not the product failing)");
        return;
    }
    let now = store.now();
    let offset = store.local_offset_seconds();
    // The tab strip, Excel-anchored in spirit. It is a walk of the
    // slots, not of the pages: a slot holding nothing still shows.
    let mut strip = String::new();
    for (i, tab) in store.tabs().enumerate() {
        let marker = if tab.page().map(Sheet::id) == current {
            "▸"
        } else {
            " "
        };
        let held = if tab.page().is_some_and(|page| page.is_held(now)) {
            "⏸ "
        } else {
            ""
        };
        strip.push_str(&format!("[{marker}{} {held}{}]", i + 1, tab.label(offset)));
    }
    strip.push_str(&format!("[◌ {}]", store.ledger().count()));
    println!("{strip}");

    let Some(tab) = current.and_then(|id| tab_holding(store, id)) else {
        return;
    };
    let Some(sheet) = tab.page() else {
        return;
    };
    let held = if sheet.is_held(now) {
        format!(
            " · held, lapses in {}",
            companion_core::ttl::human_remaining(sheet.hold_remaining(now))
        )
    } else {
        String::new()
    };
    println!(
        "┌ {} ── {} of {}{held} ┐",
        tab.label(offset),
        sheet.remaining_label(now),
        tab.rung()
    );
    let mut chip_no = 0;
    for segment in sheet.segments() {
        match segment {
            Segment::Ink(text) => {
                for line in text.lines() {
                    println!("│ {line}");
                }
            }
            Segment::Chip(chip_id) => {
                if let Some(chip) = sheet.chip(*chip_id) {
                    chip_no += 1;
                    let concealed = chip
                        .conceal()
                        .map(|p| format!(" ↗ receipt {}", p.receipt_id))
                        .unwrap_or_default();
                    println!(
                        "│ {chip_no}· [ {} · {} ]{concealed}",
                        chip.excerpt(),
                        chip.size_label()
                    );
                }
            }
        }
    }
    let gauge = gauge_glyphs(
        sheet.fraction_remaining(tab.rung(), now),
        sheet.last_hour(now),
    );
    println!("└ {gauge} ┘");
}

/// The slot a page is standing in, which is where its label and its
/// rung live now.
fn tab_holding(store: &SheetStore<ManualClock>, page: SheetId) -> Option<&Tab> {
    store
        .tabs()
        .find(|tab| tab.page().map(Sheet::id) == Some(page))
}

fn gauge_glyphs(fraction: f32, last_hour: bool) -> String {
    const WIDTH: usize = 24;
    let filled = ((fraction * WIDTH as f32).round() as usize).min(WIDTH);
    let fill = if last_hour { '▚' } else { '█' };
    let mut g: String = std::iter::repeat_n(fill, filled).collect();
    g.extend(std::iter::repeat_n('░', WIDTH - filled));
    if last_hour {
        g.push_str(" ⚠ last hour");
    }
    g
}

fn copy_out(
    store: &mut SheetStore<ManualClock>,
    pb: &mut MemoryPasteboard,
    page: SheetId,
    arg: &str,
) {
    let Some(raw) = nth_chip(store, page, arg) else {
        println!("no such chip");
        return;
    };
    let id = companion_core::ChipId::from_raw(raw);
    let Some((bytes, meta)) = store.copy_out_chip(id) else {
        return;
    };
    let kind = match meta {
        companion_core::ChipMeta::Text { .. } => ContentKind::Text,
        companion_core::ChipMeta::Image { .. } => ContentKind::Image,
    };
    // Chips are sealed by definition: outbound copies always carry the
    // `ConcealedType` mark (and the transient mark, as every write does).
    pb.write(
        bytes,
        kind,
        WriteOptions {
            nspasteboard_concealed: true,
        },
    );
    // Egress to the pasteboard is auditable: the ledger keeps the fact,
    // never the bytes (ADR-0012).
    store.record_sent(id, DestinationClass::Clipboard);
    println!(
        "on the clipboard, marked transient + ConcealedType (clipboard managers will skip it). \
         the chip stays — multi-paste away."
    );
}

fn clear(pb: &mut MemoryPasteboard) {
    let count = pb.change_count();
    if pb.clear_if_unchanged(count) {
        println!("clipboard cleared (it still held our write).");
    } else {
        println!("left alone — the clipboard changed since our copy.");
    }
}

/// The slot a page stands in. The strip's gestures address the slot,
/// the page's own gestures address the page, and this is the one place
/// the demo turns one into the other.
fn slot(store: &SheetStore<ManualClock>, page: SheetId) -> Option<TabId> {
    store
        .tabs()
        .find(|tab| tab.page().map(Sheet::id) == Some(page))
        .map(Tab::id)
}

fn cycle_rung(store: &mut SheetStore<ManualClock>, page: SheetId) {
    let Some(tab) = slot(store, page) else {
        println!("no such page");
        return;
    };
    match store.cycle_rung(tab) {
        Some(rung) => println!("clock reset: {rung} from now"),
        None => println!("no such page"),
    }
}

fn pause(store: &mut SheetStore<ManualClock>, page: SheetId) {
    let Some(tab) = slot(store, page) else {
        println!("no such page");
        return;
    };
    if store.pause_press(tab) {
        let now = store.now();
        let sheet = store.sheet(page).expect("just pressed");
        if sheet.is_held(now) {
            println!(
                "held{} — lapses in {}. the clock is frozen; the rung is not extended.",
                if sheet.hold_topped_up(now) {
                    ", topped up"
                } else {
                    ""
                },
                companion_core::ttl::human_remaining(sheet.hold_remaining(now))
            );
        } else {
            println!(
                "released — the countdown resumes at {}.",
                companion_core::ttl::human_remaining(sheet.remaining(now))
            );
        }
    } else {
        println!("nothing to hold");
    }
}

fn ledger(store: &SheetStore<ManualClock>) {
    let mut any = false;
    for record in store.ledger() {
        any = true;
        let event = record.event().to_string();
        println!(
            "◌ {event:<9} {} [{}] {} → {}",
            record.item(),
            record.size(),
            record.title(),
            record.destination()
        );
    }
    if !any {
        println!("(the ledger is empty)");
    }
}

fn tick(
    store: &mut SheetStore<ManualClock>,
    clock: &ManualClock,
    arg: &str,
    current: &mut Option<SheetId>,
) {
    let Some(delta) = parse_duration(arg.trim()) else {
        println!("usage: tick <e.g. 2h, 45m, 30s, 1d>");
        return;
    };
    clock.advance(delta);
    let expired = store.expire_due();
    // In the app expiry is silent — the page is simply gone at next
    // glance, one metadata record behind it. The demo narrates for the
    // observer's benefit.
    if !expired.is_empty() {
        println!(
            "(+{arg}) {} page(s) reached zero: sealed bytes zeroized, one record each.",
            expired.len()
        );
        if current.and_then(|id| store.sheet(id)).is_none() {
            *current = store.sheets().next().map(Sheet::id);
        }
    } else {
        println!("(+{arg})");
    }
    match store.next_event() {
        Some(at) => println!(
            "next armed timer: {} from now (the only timer there is)",
            companion_core::ttl::human_remaining(at - store.now())
        ),
        None => println!("no timers armed — idle CPU is 0% by construction"),
    }
}

fn parse_duration(arg: &str) -> Option<Duration> {
    let mut chars = arg.chars();
    let unit = chars.next_back()?;
    let value: u64 = chars.as_str().parse().ok()?;
    let secs = match unit {
        's' => value,
        'm' => value * 60,
        'h' => value * 3600,
        'd' => value * 86_400,
        _ => return None,
    };
    Some(Duration::from_secs(secs))
}

/// Resolve `conceal <n|page>` / `send <n|page>` into a payload without
/// letting the demo hold plaintext longer than the call.
fn payload_for(
    store: &SheetStore<ManualClock>,
    page: SheetId,
    arg: &str,
) -> Option<zeroize::Zeroizing<String>> {
    if arg.trim() == "page" {
        match store.sheet_payload(page) {
            Ok(payload) => Some(payload),
            Err(e) => {
                println!("refused: {e}");
                None
            }
        }
    } else {
        let raw = nth_chip(store, page, arg)?;
        let bytes = store.chip_payload(companion_core::ChipId::from_raw(raw))?;
        match std::str::from_utf8(&bytes) {
            Ok(text) => Some(zeroize::Zeroizing::new(text.to_string())),
            Err(_) => {
                println!("v1 conceals text; the v3 conceal payload is text-shaped");
                None
            }
        }
    }
}

fn conceal(store: &mut SheetStore<ManualClock>, page: SheetId, arg: &str) {
    let now = store.now();
    let Some(text) = payload_for(store, page, arg) else {
        if !arg.trim().is_empty() && arg.trim() != "page" && nth_chip(store, page, arg).is_none() {
            println!("usage: conceal <chip #|page>");
        }
        return;
    };
    let remaining = store.sheet(page).map_or(0, |s| s.remaining(now).as_secs());
    let snapped = snap_ttl(remaining, ALLOWED_TTLS).expect("non-empty ladder");
    let chars = text.chars().count();

    // Build the real request through the real client — then don't send it.
    let api = Api::new(DEMO_SERVER, Box::new(NoAuth));
    let payload = ConcealPayload::new(text.as_str(), "eu.onetimesecret.com").with_ttl(snapped);
    let request = api
        .guest_conceal_request(&payload)
        .expect("payload serializes");

    println!("── conceal · DRY RUN — nothing leaves this machine ──");
    println!("   {} {}", request.method, request.url);
    for (name, value) in &request.headers {
        println!("   {name}: {value}");
    }
    println!(
        "   {{\"secret\":{{\"kind\":\"conceal\",\"secret\":\"{}\",\"share_domain\":\"eu.onetimesecret.com\",\"ttl\":{snapped}}}}}",
        "•".repeat(chars.min(12))
    );
    println!(
        "   ttl: {} remaining on the page → {} (snapped down; never outlives intent)",
        companion_core::ttl::human_remaining(Duration::from_secs(remaining)),
        companion_core::ttl::human_remaining(Duration::from_secs(snapped)),
    );
    if let Some(raw) = nth_chip(store, page, arg) {
        store.mark_chip_concealed(companion_core::ChipId::from_raw(raw), "dry-run".into());
        println!(
            "   chip marked concealed; in the app: link on clipboard, offer to burn local copy."
        );
    }
}

/// `send`'s live counterpart to `conceal`'s dry run: a real POST through
/// the real transport (`companion-transport`), authenticated from
/// Keychain-or-dev-store credentials when `login` has set them,
/// otherwise the guest route. Only the receipt id is retained on the
/// chip; the share link lands on the clipboard, not in any local
/// history (docs/spec/05). Sealed bytes travel core → client directly.
fn send(store: &mut SheetStore<ManualClock>, page: SheetId, arg: &str) {
    let now = store.now();
    let Some(text) = payload_for(store, page, arg) else {
        return;
    };
    let remaining = store.sheet(page).map_or(0, |s| s.remaining(now).as_secs());
    let snapped = snap_ttl(remaining, ALLOWED_TTLS).expect("non-empty ladder");
    let payload = ConcealPayload::new(text.as_str(), "eu.onetimesecret.com").with_ttl(snapped);
    let transport = UreqTransport::new();
    let creds = default_credential_store();
    let stored = creds
        .load(CRED_ACCOUNT_KEY)
        .ok()
        .zip(creds.load(CRED_ACCOUNT_SECRET).ok());

    println!("── conceal · LIVE — POSTing to {DEMO_SERVER} ──");
    let result = if let Some((key, secret)) = stored {
        let auth = BasicAuth::new(
            String::from_utf8_lossy(&key).into_owned(),
            String::from_utf8_lossy(&secret).into_owned(),
        );
        Client::new(DEMO_SERVER, Box::new(auth), transport).conceal(&payload)
    } else {
        println!(
            "   (no stored credentials — using the guest route; `login <key> <secret>` to authenticate)"
        );
        Client::new(DEMO_SERVER, Box::new(NoAuth), transport).guest_conceal(&payload)
    };

    match result {
        Ok(data) => {
            let link = share_link(DEMO_SERVER, &data);
            let receipt = data.receipt.identifier.clone();
            land_link_on_clipboard(&link);
            if let Some(raw) = nth_chip(store, page, arg) {
                store.mark_chip_concealed(companion_core::ChipId::from_raw(raw), receipt.clone());
            }
            println!("   {link}");
            println!("   on the clipboard. only the receipt id ({receipt}) is retained.");
        }
        Err(e) => println!("   failed: {e}"),
    }
}

#[cfg(target_os = "macos")]
fn land_link_on_clipboard(link: &str) {
    use companion_pasteboard::SystemPasteboard;
    use zeroize::Zeroizing;

    let mut pb = SystemPasteboard::new();
    pb.write(
        Zeroizing::new(link.as_bytes().to_vec()),
        ContentKind::Text,
        WriteOptions {
            nspasteboard_concealed: false,
        },
    );
}

#[cfg(not(target_os = "macos"))]
fn land_link_on_clipboard(_link: &str) {
    println!("   (not on macOS — nothing else will land this on a real clipboard)");
}

fn login(rest: &str) {
    let mut parts = rest.split_whitespace();
    let (Some(key), Some(secret)) = (parts.next(), parts.next()) else {
        println!("usage: login <api-key> <api-secret>");
        return;
    };
    let creds = default_credential_store();
    if let Err(e) = creds
        .store(CRED_ACCOUNT_KEY, key.as_bytes())
        .and_then(|()| creds.store(CRED_ACCOUNT_SECRET, secret.as_bytes()))
    {
        println!("failed to store credentials: {e}");
        return;
    }
    let backend = if cfg!(target_os = "macos") {
        "macOS Keychain"
    } else {
        "in-memory dev store"
    };
    println!("credentials stored ({backend}). `send` will now authenticate.");
}

fn logout() {
    let creds = default_credential_store();
    let _ = creds.delete(CRED_ACCOUNT_KEY);
    let _ = creds.delete(CRED_ACCOUNT_SECRET);
    println!("credentials removed. `send` will use the guest route.");
}
