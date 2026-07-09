// This is a spike (spikes/README.md): disposable evidence for
// ADR-0002, not product code. It is Rust-native, so unlike swift-panel
// it talks to `companion-core` directly — no C-ABI seam needed, since
// there is no non-Rust caller here.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

#[cfg(target_os = "macos")]
mod panel;

use std::sync::Mutex;

use companion_core::{CellId, CellKind, CellStore, LifecycleState, SystemClock, TTL_LADDER, Ttl};
use companion_pasteboard::{ChangeCount, ContentKind, MemoryPasteboard, Pasteboard, WriteOptions};
use tauri::{Emitter, Manager, WebviewWindow};

/// Mirrors `companion-ffi`'s `Companion`: the store, and the pasteboard
/// the core itself writes to on copy-out (the in-process stand-in used
/// everywhere the real `NSPasteboard` adapter isn't wired to ingest yet —
/// issue #4, not this spike's scope).
struct Companion {
    store: CellStore<SystemClock>,
    pasteboard: MemoryPasteboard,
    last_write: Option<ChangeCount>,
}

struct AppState(Mutex<Companion>);

fn ttl_to_code(ttl: Ttl) -> i32 {
    TTL_LADDER
        .iter()
        .position(|d| *d == ttl.duration())
        .and_then(|i| i32::try_from(i).ok())
        .unwrap_or(-1)
}

/// One cell's non-secret snapshot — the same fields `companion-ffi`
/// exposes over the C ABI, built directly from `companion-core` here.
fn summary_json(cell: &companion_core::Cell, now: std::time::Instant) -> serde_json::Value {
    let remaining = cell.remaining(now);
    serde_json::json!({
        "id": cell.id().raw(),
        "kind": match cell.kind() {
            CellKind::Text => "text",
            CellKind::Image => "image",
        },
        "state": match cell.state(now) {
            LifecycleState::Staged => "staged",
            LifecycleState::Draining => "draining",
            LifecycleState::LastHour => "last_hour",
            LifecycleState::Expired => "expired",
        },
        "concealed": cell.concealed(),
        "detected_as": cell.detected_as(),
        "ttl_code": ttl_to_code(cell.ttl()),
        "ttl_label": cell.ttl().to_string(),
        "remaining_ms": u64::try_from(remaining.as_millis()).unwrap_or(u64::MAX),
        "remaining_label": cell.ttl_label(now),
        "recognition": cell.recognition_line(),
        "display_size": cell.content().display_size(),
        "promoted": cell.promotion().is_some(),
    })
}

#[tauri::command]
fn list_cells(state: tauri::State<AppState>) -> Vec<serde_json::Value> {
    let guard = state.0.lock().unwrap();
    let now = guard.store.now();
    guard.store.cells().map(|c| summary_json(c, now)).collect()
}

/// A real drag landed on the panel; staged the same way swift-panel's
/// `devSeedPasteboard`-via-drop path stages it — see module docs for why
/// this crate skips the pasteboard-read half of ingest entirely.
#[tauri::command]
fn receive_drop(text: String, state: tauri::State<AppState>) -> u64 {
    let mut guard = state.0.lock().unwrap();
    guard
        .store
        .stage_text(&text, None)
        .map(|id| id.raw())
        .unwrap_or(0)
}

#[tauri::command]
fn discard_cell(id: u64, state: tauri::State<AppState>) -> bool {
    let mut guard = state.0.lock().unwrap();
    guard.store.discard(CellId::from_raw(id))
}

#[tauri::command]
fn cycle_ttl(id: u64, state: tauri::State<AppState>) -> i32 {
    let mut guard = state.0.lock().unwrap();
    match guard.store.cycle_ttl(CellId::from_raw(id)) {
        Some(ttl) => ttl_to_code(ttl),
        None => -1,
    }
}

/// Copy a cell back out; the core writes the pasteboard stand-in itself,
/// exactly as `companion_cell_copy_out` does over the C ABI.
#[tauri::command]
fn copy_out(id: u64, state: tauri::State<AppState>) -> bool {
    let mut guard = state.0.lock().unwrap();
    let Some(cell) = guard.store.get(CellId::from_raw(id)) else {
        return false;
    };
    let (kind, concealed) = (cell.kind(), cell.concealed());
    let Some(bytes) = guard.store.copy_out(CellId::from_raw(id)) else {
        return false;
    };
    let kind = match kind {
        CellKind::Text => ContentKind::Text,
        CellKind::Image => ContentKind::Image,
    };
    let receipt = guard
        .pasteboard
        .write(bytes, kind, WriteOptions { concealed });
    guard.last_write = Some(receipt);
    true
}

#[cfg(target_os = "macos")]
#[tauri::command]
fn toggle_panel(window: WebviewWindow) {
    if panel::is_visible(&window) {
        panel::hide(&window);
        let _ = window.emit("panel-visibility", serde_json::json!({"visible": false}));
    } else {
        panel::show(&window);
        let _ = window.emit("panel-visibility", serde_json::json!({"visible": true}));
    }
}

/// Arm exactly one scheduled wakeup at the store's earliest deadline —
/// never a poll loop (docs/spec/05). Runs independent of panel
/// visibility, same as `PanelModel.armExpiryTimer`: an unseen cell must
/// still expire and wipe its buffer on time.
fn arm_expiry(app: tauri::AppHandle) {
    let state = app.state::<AppState>();
    let deadline_ms = {
        let guard = state.0.lock().unwrap();
        guard
            .store
            .next_deadline()
            .map(|d| d.saturating_duration_since(guard.store.now()).as_millis() as u64)
    };
    let Some(ms) = deadline_ms else { return };
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(ms.max(50))).await;
        {
            let state = app.state::<AppState>();
            let mut guard = state.0.lock().unwrap();
            guard.store.expire_due();
        }
        arm_expiry(app);
    });
}

fn main() {
    companion_core::harden_process();

    tauri::Builder::default()
        .manage(AppState(Mutex::new(Companion {
            store: CellStore::new(SystemClock),
            pasteboard: MemoryPasteboard::new(),
            last_write: None,
        })))
        .invoke_handler(tauri::generate_handler![
            list_cells,
            receive_drop,
            discard_cell,
            cycle_ttl,
            copy_out,
            toggle_panel,
        ])
        .setup(|app| {
            let window = app
                .get_webview_window("panel")
                .expect("the `panel` window is declared in tauri.conf.json");

            #[cfg(target_os = "macos")]
            {
                app.set_activation_policy(tauri::ActivationPolicy::Accessory);
                panel::configure(&window);
                build_tray(app.handle(), window.clone())?;

                // Testing aid, mirrors swift-panel's COMPANION_AUTOSHOW:
                // makes the non-activating claim scriptable (lsappinfo
                // polling) without needing a synthetic click.
                if std::env::var_os("COMPANION_AUTOSHOW").is_some() {
                    panel::show(&window);
                    let _ = window.emit("panel-visibility", serde_json::json!({"visible": true}));
                }
            }

            arm_expiry(app.handle().clone());
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(target_os = "macos")]
fn build_tray(app: &tauri::AppHandle, window: WebviewWindow) -> tauri::Result<()> {
    use tauri::tray::{TrayIconBuilder, TrayIconEvent};

    // A 22x22 template icon: a filled ring, alpha-only (macOS recolors
    // template images itself for light/dark menu bars) — the tray
    // equivalent of swift-panel's SF Symbol "hourglass" status item.
    const SIZE: u32 = 22;
    let icon = {
        let mut rgba = vec![0u8; (SIZE * SIZE * 4) as usize];
        let center = SIZE as f32 / 2.0;
        let (outer, inner) = (9.0f32, 6.0f32);
        for y in 0..SIZE {
            for x in 0..SIZE {
                let dx = x as f32 + 0.5 - center;
                let dy = y as f32 + 0.5 - center;
                let dist = (dx * dx + dy * dy).sqrt();
                let alpha = if dist <= outer && dist >= inner {
                    255
                } else {
                    0
                };
                let idx = ((y * SIZE + x) * 4) as usize;
                rgba[idx + 3] = alpha;
            }
        }
        tauri::image::Image::new_owned(rgba, SIZE, SIZE)
    };

    TrayIconBuilder::with_id("companion")
        .icon(icon)
        .icon_as_template(true)
        .on_tray_icon_event(move |_tray, event| {
            if let TrayIconEvent::Click {
                button_state: tauri::tray::MouseButtonState::Up,
                ..
            } = event
            {
                if panel::is_visible(&window) {
                    panel::hide(&window);
                    let _ = window.emit("panel-visibility", serde_json::json!({"visible": false}));
                } else {
                    panel::show(&window);
                    let _ = window.emit("panel-visibility", serde_json::json!({"visible": true}));
                }
            }
        })
        .build(app)?;
    Ok(())
}
