//! The objc2 side door: Tauri's `WebviewWindow` is a plain `NSWindow` with
//! no non-activating-panel concept, and its own `show()`/`set_visible()`
//! hard-codes `makeKeyAndOrderFront` (tao's
//! `platform_impl/macos/window.rs::set_visible`, called unconditionally
//! regardless of the window's `focused` construction attribute). Reaching
//! the same "never steals focus" behavior `PanelController.swift` gets
//! for free from `NSPanel` means never calling Tauri's visibility API and
//! driving the raw `NSWindow` here instead — the asymmetry this spike
//! exists to measure (ADR-0002).
use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2_app_kit::{
    NSStatusWindowLevel, NSWindow, NSWindowCollectionBehavior, NSWindowSharingType,
    NSWindowStyleMask,
};
use tauri::WebviewWindow;

/// # Safety
/// `window` must have a live native `NSWindow` (true for any window handed
/// to a `setup`/command callback while the app is running).
unsafe fn ns_window(window: &WebviewWindow) -> Retained<NSWindow> {
    let ptr = window.ns_window().expect("panel window has no NSWindow");
    // `ns_window()` hands back an autoreleased pointer (see tauri's own
    // impl: `Retained::autorelease_ptr`); retain it so it outlives the
    // autorelease pool of this call.
    unsafe { Retained::retain(ptr.cast::<NSWindow>()) }.expect("null NSWindow")
}

/// Apply the panel's non-activating, capture-excluded posture once, right
/// after the window is created. Mirrors `PanelController.init`.
pub fn configure(window: &WebviewWindow) {
    let win = unsafe { ns_window(window) };
    win.setStyleMask(win.styleMask() | NSWindowStyleMask::NonactivatingPanel);
    win.setLevel(NSStatusWindowLevel);
    win.setHidesOnDeactivate(false);
    // Capture exclusion (docs/spec/05) — see the identical note in
    // PanelController.swift: on by default in the spike, to confirm it's
    // compatible with the rest of the panel's behavior.
    win.setSharingType(NSWindowSharingType::None);
    win.setCollectionBehavior(
        NSWindowCollectionBehavior::CanJoinAllSpaces
            | NSWindowCollectionBehavior::FullScreenAuxiliary,
    );
}

/// Show docked to the screen edge, without ever calling Tauri's `show()`
/// (see module docs) — `orderFrontRegardless`, never `makeKeyAndOrderFront`.
pub fn show(window: &WebviewWindow) {
    position_against_edge(window);
    let win = unsafe { ns_window(window) };
    win.orderFrontRegardless();
}

pub fn hide(window: &WebviewWindow) {
    let win = unsafe { ns_window(window) };
    win.orderOut(None::<&AnyObject>);
}

pub fn is_visible(window: &WebviewWindow) -> bool {
    unsafe { ns_window(window) }.isVisible()
}

fn position_against_edge(window: &WebviewWindow) {
    let Ok(Some(monitor)) = window.primary_monitor() else {
        return;
    };
    let Ok(size) = window.outer_size() else {
        return;
    };
    let work_area = monitor.work_area();
    let margin: i32 = 12;
    // Dock to the right edge, matching PanelController's default `.maxX`.
    let x = work_area.position.x + work_area.size.width as i32 - size.width as i32 - margin;
    let y = work_area.position.y + margin;
    let _ = window.set_position(tauri::PhysicalPosition::new(x, y));
}
