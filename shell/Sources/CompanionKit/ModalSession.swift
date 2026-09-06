import AppKit

/// A modal of ours, bracketed so the rest of the app can tell when it
/// has returned.
///
/// Every panel and alert this app runs is modal and blocking: the open
/// and save panels, the two file reviews, the tab rename prompt, the
/// quit notice. What the surface needs from all of them is one fact at
/// two moments. While one is up, a press into it must not be read as a
/// press into another application; and when it returns, however it
/// returned, the surface has to be raised and in front again, because
/// the panel took the keyboard on its way in and AppKit promises
/// nothing about where the keyboard goes on the way out.
///
/// The first moment is AppKit's to answer, and `isRunning` only reads
/// it. `NSApp.modalWindow` is the panel for the whole of `runModal`,
/// and it is so, measured, even for the open and save panels, which
/// modern macOS draws in a separate service process and which a global
/// event monitor therefore reports as clicks into some other app. The
/// AppKit fact is preferred over a flag kept by hand because it holds
/// for every modal in the process, including one nobody remembered to
/// wrap.
///
/// The second moment has no notification of AppKit's, so the bracket
/// supplies it: `run` posts `didEndNotification` once the body has
/// returned, on the same turn, whatever the body answered. It goes out
/// on a notification centre rather than back through the model because
/// the callers are spread across the file coordinator, the tab strip
/// and the app delegate, and the form factor that answers is the one
/// that knows what a raise is.
public enum ModalSession {
    /// Posted after a modal of ours has returned, opened, saved,
    /// confirmed or cancelled alike. The object is nil; nothing about
    /// which panel it was bears on what the surface does next.
    public static let didEndNotification = Notification.Name("CompanionKit.ModalSession.didEnd")

    /// Whether the app is inside a modal session right now. Read at the
    /// moment a press is judged rather than at the moment it happened,
    /// which is sound here for a reason the menu rule cannot rely on:
    /// the main actor's queue drains during a modal session, so the
    /// deferred handler runs while the panel is still up, and the press
    /// that dismisses a panel is a mouse down while the panel returns
    /// on the mouse up that follows it.
    ///
    /// `NSApp` is read as the optional it is. It is nil in a process
    /// that never made an application, which the test runner is until
    /// some AppKit view forces one, and unwrapping it there traps. No
    /// application means no modal, which is the closed answer: the
    /// press rests the surface.
    @MainActor
    public static var isRunning: Bool { NSApp?.modalWindow != nil }

    /// Run a modal body and say so when it is over.
    ///
    /// The centre is injectable so a test can watch the notification
    /// without a panel on screen; the body under test is then a plain
    /// closure standing in for `runModal`.
    @MainActor
    @discardableResult
    public static func run<T>(center: NotificationCenter = .default, _ body: () -> T) -> T {
        defer { center.post(name: didEndNotification, object: nil) }
        return body()
    }
}
