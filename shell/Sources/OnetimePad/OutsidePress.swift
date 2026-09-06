import Foundation

/// Whether a press the global monitor reported should rest the surface,
/// given everything the app can know about where it landed.
///
/// The monitor sees every press this app's own windows did not receive,
/// and two kinds of those are not outside anything. Our menus track in
/// windows the window server owns (`MenuTracking`, issue #41). The open
/// and save panels are drawn by a separate service process on modern
/// macOS, so a click into one of them, on a folder, on Cancel, on Open
/// itself, arrives here looking like a click into another application,
/// and resting on it took the pad away at the moment the person chose
/// their file (dogfood phase 4). Both facts are read by the caller and
/// judged here, so the rule is one sentence in one place: a press rests
/// the surface when neither a menu nor a modal of ours owns it.
enum OutsidePress {
    static func rests(claimedByMenu: Bool, modalSessionRunning: Bool) -> Bool {
        !claimedByMenu && !modalSessionRunning
    }
}
