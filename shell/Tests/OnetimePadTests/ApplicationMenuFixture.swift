import AppKit

@MainActor
func prepareApplicationMenuRoles() {
    _ = NSApplication.shared
    let main = NSApp.mainMenu ?? NSMenu(title: "Application Menu Fixture")
    NSApp.mainMenu = main
    func attach(_ title: String, to parent: NSMenu) -> NSMenu {
        let menu = NSMenu(title: title)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        parent.addItem(item)
        return menu
    }
    if NSApp.windowsMenu == nil { NSApp.windowsMenu = attach("Window", to: main) }
    if NSApp.helpMenu == nil { NSApp.helpMenu = attach("Help", to: main) }
    if NSApp.servicesMenu == nil {
        let application = attach("Application", to: main)
        NSApp.servicesMenu = attach("Services", to: application)
    }
}
