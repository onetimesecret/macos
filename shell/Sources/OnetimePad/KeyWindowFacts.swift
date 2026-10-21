import AppKit
import Combine

/// Two facts about the key window, read from AppKit as windows become
/// and resign key, for the File menu's ⌘W item (issue #201): whether a
/// companion window (Settings, Send Feedback, About) is key, and whether
/// the key window has a close box `performClose:` can act on.
@MainActor
final class KeyWindowFacts: ObservableObject {
    @Published private(set) var companionIsKey = false
    @Published private(set) var canClose = false
    private let isCompanionWindow: (NSWindow) -> Bool
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(center: NotificationCenter = .default, isCompanionWindow: @escaping (NSWindow) -> Bool) {
        self.center = center
        self.isCompanionWindow = isCompanionWindow
    }

    /// Whether `performClose:` would close the window rather than beep:
    /// a close box, enabled, and no sheet attached.
    static func canClose(_ window: NSWindow?) -> Bool {
        guard let window, window.styleMask.contains(.closable), window.attachedSheet == nil
        else { return false }
        return window.standardWindowButton(.closeButton)?.isEnabled ?? true
    }

    /// Follows every window's key status for the life of the process,
    /// which is the delegate's; the observers are never removed.
    func observe() {
        guard observers.isEmpty else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func refresh() {
        stand(NSApp?.keyWindow)
    }

    /// Publishes each fact only when it moves.
    func stand(_ window: NSWindow?) {
        let companion = window.map(isCompanionWindow) ?? false
        if companionIsKey != companion { companionIsKey = companion }
        let closable = Self.canClose(window)
        if canClose != closable { canClose = closable }
    }
}
