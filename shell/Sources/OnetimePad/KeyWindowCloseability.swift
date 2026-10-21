import AppKit
import Combine

/// Whether the key window can close, read from AppKit as windows become
/// and resign key. The File menu's Close Window item dims on it (issue
/// #201), so ⌘W never promises a close with no key window or a
/// borderless one, which `performClose:` would answer with a beep.
@MainActor
final class KeyWindowCloseability: ObservableObject {
    @Published private(set) var canClose = false
    private var observers: [NSObjectProtocol] = []

    /// Whether `performClose:` has a close box to act on.
    static func canClose(_ window: NSWindow?) -> Bool {
        window?.styleMask.contains(.closable) ?? false
    }

    /// Follows every window's key status for the life of the process.
    func observe(_ center: NotificationCenter = .default) {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                // AppKit posts both on the main thread.
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func refresh() {
        stand(Self.canClose(NSApp?.keyWindow))
    }

    func stand(_ canClose: Bool) {
        if self.canClose != canClose { self.canClose = canClose }
    }
}
