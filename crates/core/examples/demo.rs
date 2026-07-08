//! Headless walkthrough of the `SleeperCell` lifecycle — the panel, in a
//! terminal, with time under your control.
//!
//! ```text
//! cargo run -p companion-core --example demo
//! ```
//!
//! Content stages into zeroizing cells, secret-shaped text arrives
//! masked, TTL labels cycle the ladder, the ring drains as you `tick`
//! the clock, expiry is silent, and `promote` dry-runs the v3 conceal
//! request without a byte leaving the machine.

use std::io::{BufRead, Write as _};
use std::time::Duration;

use companion_core::{Cell, CellKind, CellStore, LifecycleState, ManualClock};
use companion_pasteboard::{ContentKind, MemoryPasteboard, Pasteboard, WriteOptions};
use ots_client::{Api, ConcealPayload, NoAuth, snap_ttl};

const DEMO_SERVER: &str = "https://eu.onetimesecret.com";

/// Server-allowed TTLs a real client would learn from the config
/// endpoint at connection-test time (docs/spec/05).
const ALLOWED_TTLS: &[u64] = &[300, 1800, 3600, 14_400, 28_800, 86_400, 259_200, 604_800];

fn main() {
    // No core dumps while secrets are held; buffers are mlocked besides.
    companion_core::harden_process();
    let clock = ManualClock::new();
    let mut store = CellStore::new(clock.clone());
    let mut pasteboard = MemoryPasteboard::new();

    println!("╭──────────────────────────────────────────────────────────────╮");
    println!("│  SleeperCell demo — the core crate, headless                 │");
    println!("│  Drop or paste something on its way somewhere else.          │");
    println!("╰──────────────────────────────────────────────────────────────╯");
    println!("Type `help` for commands. Time only moves when you `tick` it.\n");

    let stdin = std::io::stdin();
    loop {
        print!("airlock> ");
        std::io::stdout().flush().ok();
        let Some(Ok(line)) = stdin.lock().lines().next() else {
            break;
        };
        let line = line.trim();
        let (cmd, rest) = line.split_once(' ').unwrap_or((line, ""));
        match cmd {
            "" => {}
            "help" | "?" => help(),
            "paste" | "p" => paste(&mut store, rest),
            "image" => image(&mut store),
            "ls" | "l" => render(&store),
            "tick" | "t" => tick(&mut store, &clock, rest),
            "ttl" => cycle_ttl(&mut store, rest),
            "copy" | "c" => copy_out(&mut store, &mut pasteboard, rest),
            "clear" => clear(&mut pasteboard),
            "peek" => peek(&store, rest),
            "promote" | "link" => promote(&mut store, rest),
            "discard" | "d" | "burn" => discard(&mut store, rest),
            "quit" | "q" | "exit" => break,
            other => println!("unknown command `{other}` — try `help`"),
        }
    }
    let held = store.len();
    if held > 0 {
        println!("exit is total amnesia: {held} cell(s) zeroized. nothing persists.");
    }
}

fn help() {
    println!(
        "\
  paste <text>     stage text (secret-shaped content arrives masked)
  image            stage a pretend screenshot
  ls               the panel: ring, kind, recognition line, TTL label
  tick <2h|30m|5s> advance the clock; due cells expire silently
  ttl <n>          click cell n's TTL label: next rung, clock reset
  copy <n>         copy cell n back out (marked concealed + transient)
  clear            clear-after-copy: only if the clipboard is still ours
  peek <n>         reveal cell n (the Space overlay; deliberate, logged)
  promote <n>      dry-run the v3 conceal request — nothing is sent
  discard <n>      discard now (zeroized immediately)
  quit"
    );
}

fn nth(store: &CellStore<ManualClock>, arg: &str) -> Option<companion_core::CellId> {
    let n: usize = arg.trim().parse().ok()?;
    store.cells().nth(n.checked_sub(1)?).map(Cell::id)
}

fn paste(store: &mut CellStore<ManualClock>, text: &str) {
    if text.is_empty() {
        println!("usage: paste <text>");
        return;
    }
    match store.stage_text(text, None) {
        Ok(id) => {
            let cell = store.get(id).expect("just staged");
            match cell.detected_as() {
                Some(shape) => println!(
                    "staged, masked — looks like a {shape}. expires in {}.",
                    cell.ttl_label(store.now())
                ),
                None => println!("staged. expires in {}.", cell.ttl_label(store.now())),
            }
        }
        Err(e) => println!("refused: {e}"),
    }
}

fn image(store: &mut CellStore<ManualClock>) {
    // A pretend 212 KB screenshot, the visual-board example.
    match store.stage_image(vec![0x89; 212 * 1024], None) {
        Ok(_) => println!("staged. the cell appearing is the receipt."),
        Err(e) => println!("refused: {e}"),
    }
}

fn render(store: &CellStore<ManualClock>) {
    if store.is_empty() {
        println!("(empty — the system working, not the product failing)");
        return;
    }
    let now = store.now();
    println!("  #  ring       kind  cell");
    for (i, cell) in store.cells().enumerate() {
        let f = cell.fraction_remaining(now);
        let ring = ring_glyph(f);
        let kind = match (cell.concealed(), cell.kind()) {
            (true, _) => "⚿ ",
            (false, CellKind::Text) => "Aa",
            (false, CellKind::Image) => "▣ ",
        };
        let urgency = match cell.state(now) {
            LifecycleState::LastHour => " ⚠ last hour",
            _ => "",
        };
        let promoted = cell
            .promotion()
            .map(|p| format!(" ↗ receipt {}", p.receipt_id))
            .unwrap_or_default();
        println!(
            "  {}  {ring} {:>3.0}%  {kind}   {:<44} [{}]{urgency}{promoted}",
            i + 1,
            f * 100.0,
            cell.recognition_line(),
            cell.ttl_label(now),
        );
    }
}

fn ring_glyph(fraction: f32) -> char {
    match (fraction * 8.0).round() as u32 {
        8 => '●',
        6 | 7 => '◕',
        4 | 5 => '◑',
        2 | 3 => '◔',
        _ => '○',
    }
}

fn tick(store: &mut CellStore<ManualClock>, clock: &ManualClock, arg: &str) {
    let Some(delta) = parse_duration(arg.trim()) else {
        println!("usage: tick <e.g. 2h, 45m, 30s, 1d>");
        return;
    };
    clock.advance(delta);
    let expired = store.expire_due();
    // In the app expiry is silent — the cell is simply gone at next
    // glance. The demo narrates for the observer's benefit.
    if !expired.is_empty() {
        println!(
            "(+{arg}) {} cell(s) reached their deadline: removed, buffers zeroized.",
            expired.len()
        );
    } else {
        println!("(+{arg})");
    }
    match store.next_deadline() {
        Some(deadline) => println!(
            "next armed timer: {} from now (the only timer there is)",
            companion_core::ttl::human_remaining(deadline - store.now())
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

fn cycle_ttl(store: &mut CellStore<ManualClock>, arg: &str) {
    match nth(store, arg).and_then(|id| store.cycle_ttl(id)) {
        Some(rung) => println!("clock reset: {rung} from now"),
        None => println!("no such cell"),
    }
}

fn copy_out(store: &mut CellStore<ManualClock>, pb: &mut MemoryPasteboard, arg: &str) {
    let Some(id) = nth(store, arg) else {
        println!("no such cell");
        return;
    };
    let cell = store.get(id).expect("id from nth");
    let kind = match cell.kind() {
        CellKind::Text => ContentKind::Text,
        CellKind::Image => ContentKind::Image,
    };
    let concealed = cell.concealed();
    let bytes = store.copy_out(id).expect("id from nth");
    pb.write(bytes, kind, WriteOptions { concealed });
    println!(
        "on the clipboard, marked transient{}. the cell keeps draining — multi-paste away.",
        if concealed {
            " + concealed (clipboard managers will skip it)"
        } else {
            ""
        }
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

fn peek(store: &CellStore<ManualClock>, arg: &str) {
    match nth(store, arg).and_then(|id| store.get(id)) {
        Some(cell) => match cell.content().as_text() {
            Some(text) => println!("┃ {text}"),
            None => println!("┃ image · {} bytes", cell.content().len()),
        },
        None => println!("no such cell"),
    }
}

fn promote(store: &mut CellStore<ManualClock>, arg: &str) {
    let Some(id) = nth(store, arg) else {
        println!("no such cell");
        return;
    };
    let now = store.now();
    let cell = store.get(id).expect("id from nth");
    let Some(text) = cell.content().as_text() else {
        println!("v1 promotes text; the v3 conceal payload is text-shaped (open question №6)");
        return;
    };
    let remaining = cell.remaining(now).as_secs();
    let snapped = snap_ttl(remaining, ALLOWED_TTLS).expect("non-empty ladder");
    let chars = text.chars().count();

    // Build the real request through the real client — then don't send it.
    let api = Api::new(DEMO_SERVER, Box::new(NoAuth));
    let payload = ConcealPayload::new(text, "eu.onetimesecret.com").with_ttl(snapped);
    let request = api
        .guest_conceal_request(&payload)
        .expect("payload serializes");

    println!("── promotion, frame 2 of 3 · DRY RUN — nothing leaves this machine ──");
    println!("   {} {}", request.method, request.url);
    for (name, value) in &request.headers {
        println!("   {name}: {value}");
    }
    println!(
        "   {{\"secret\":{{\"kind\":\"conceal\",\"secret\":\"{}\",\"share_domain\":\"eu.onetimesecret.com\",\"ttl\":{snapped}}}}}",
        "•".repeat(chars.min(12))
    );
    println!(
        "   ttl: {} remaining → {} (snapped down; never outlives intent)",
        companion_core::ttl::human_remaining(Duration::from_secs(remaining)),
        companion_core::ttl::human_remaining(Duration::from_secs(snapped)),
    );
    store.mark_promoted(id, "dry-run".into());
    println!("   cell marked promoted; in the app: link on clipboard, offer to burn local copy.");
}

fn discard(store: &mut CellStore<ManualClock>, arg: &str) {
    match nth(store, arg).map(|id| store.discard(id)) {
        Some(true) => println!("gone. buffer zeroized on the way down."),
        _ => println!("no such cell"),
    }
}
