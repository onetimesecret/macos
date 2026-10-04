import AppKit

/// SwiftUI can replace or retarget command items after launch. Keep the
/// Edit menu's undo commands on the responder chain through those updates,
/// without taking ownership of SwiftUI's menu delegate or enabled state.
@MainActor
final class UndoMenuRoutingWatch {
    private let mainMenu: () -> NSMenu?
    private let center: NotificationCenter
    private nonisolated(unsafe) var tokens: [NSObjectProtocol] = []
    private var routing = false

    init(mainMenu: @escaping () -> NSMenu?, center: NotificationCenter = .default) {
        self.mainMenu = mainMenu
        self.center = center
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification,
                     NSMenu.didBeginTrackingNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: nil) {
                [weak self] notification in
                let name = notification.name
                let menuID = (notification.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    self?.menuChanged(menuID, name: name)
                }
            })
        }
        refresh()
    }

    deinit {
        for token in tokens { center.removeObserver(token) }
    }

    private func refresh() {
        guard !routing else { return }
        routing = true
        defer { routing = false }
        BackdropAppDelegate.routeUndoRedoThroughResponder(in: mainMenu())
    }

    private func menuChanged(_ menuID: ObjectIdentifier?, name: Notification.Name) {
        guard !routing, let root = mainMenu(), let menuID else { return }
        var pending = [root]
        var belongsToMainMenu = false
        while let menu = pending.popLast() {
            if ObjectIdentifier(menu) == menuID {
                belongsToMainMenu = true
                break
            }
            pending.append(contentsOf: menu.items.compactMap(\.submenu))
        }
        guard belongsToMainMenu else { return }
        refresh()
        if name == NSMenu.didBeginTrackingNotification {
            // Refresh validation after routing in case SwiftUI reset these
            // items while preparing the menu for this tracking session.
            root.items.first(where: { $0.title == "Edit" })?.submenu?.update()
        }
    }
}
