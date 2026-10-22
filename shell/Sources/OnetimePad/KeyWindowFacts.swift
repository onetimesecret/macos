import AppKit
import Combine
import CompanionKit

/// Two facts about the key window, read from AppKit as windows become
/// and resign key, for the ⌘W and ⇧⌘W items (issue #201): what ⌘W
/// closes, and whether the key window has a close box `performClose:`
/// can act on.
@MainActor
final class KeyWindowFacts: ObservableObject {
    @Published private(set) var closeTarget: CloseChordTarget = .nothing
    @Published private(set) var canClose = false
    private let isOwnerWindow: (NSWindow) -> Bool
    private let isCompanionWindow: (NSWindow) -> Bool
    private let center: NotificationCenter
    // nonisolated(unsafe): deinit is nonisolated and the tokens are not
    // Sendable; removeObserver is thread safe and every other touch is main.
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    init(
        center: NotificationCenter = .default,
        isOwnerWindow: @escaping (NSWindow) -> Bool,
        isCompanionWindow: @escaping (NSWindow) -> Bool
    ) {
        self.center = center
        self.isOwnerWindow = isOwnerWindow
        self.isCompanionWindow = isCompanionWindow
    }

    deinit {
        for observer in observers {
            center.removeObserver(observer)
        }
    }

    /// Whether `performClose:` would close the window rather than beep:
    /// a close box, enabled, and no sheet attached. Display only: read on
    /// key turns, and `windowShouldClose:` is not asked.
    static func canClose(_ window: NSWindow?) -> Bool {
        guard let window, window.styleMask.contains(.closable), window.attachedSheet == nil
        else { return false }
        return window.standardWindowButton(.closeButton)?.isEnabled ?? true
    }

    /// Follows every window's key status. Queue nil, so the facts move
    /// inside the key change itself rather than a main queue turn later.
    func observe() {
        guard observers.isEmpty else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
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
        let target = window.map {
            CloseChordTarget(
                ownerWindowIsKey: isOwnerWindow($0), companionWindowIsKey: isCompanionWindow($0))
        } ?? .nothing
        if closeTarget != target { closeTarget = target }
        let closable = Self.canClose(window)
        if canClose != closable { canClose = closable }
    }
}
