import AppKit
import CompanionKit

/// An explanation owned by the app, before its first persistence access.
/// macOS still owns every authorization decision and password dialog.
@MainActor
enum KeychainIntroduction {
    private static let acknowledgedKey = "keychain.introduction.acknowledged.v1"

    static func showIfNeeded(defaults: UserDefaults) {
        guard !defaults.bool(forKey: acknowledgedKey) else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = text("A little help from your Keychain")
        alert.informativeText = text("OnetimePad uses two separate keys for saved pages and their history. macOS may ask you to approve access to each one.\n\nIf a password dialog appears, Allow approves that access once. Always Allow lets this app access that item again without asking each time. Choose whichever you prefer.")
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: text("Continue"))

        let graphic = NSImageView()
        graphic.image = NSImage(systemSymbolName: "key.horizontal.fill", accessibilityDescription: nil)
        graphic.contentTintColor = .systemBrown
        graphic.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        graphic.setAccessibilityElement(false)
        graphic.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let disclosure = NSTextField(wrappingLabelWithString: String(
            format: text("Saved pages: state-key\nPage history: ledger-key\nKeychain service: %@"),
            FormFactor.backdrop.credentialService))
        disclosure.font = .systemFont(ofSize: 11)
        disclosure.textColor = .secondaryLabelColor
        disclosure.isSelectable = true
        disclosure.setAccessibilityLabel(text("Keychain items used for saved pages and page history"))
        let detail = NSStackView(views: [graphic, disclosure])
        detail.orientation = .horizontal
        detail.alignment = .centerY
        detail.spacing = 14
        detail.frame = NSRect(x: 0, y: 0, width: 360, height: 70)
        alert.accessoryView = detail

        NSApp.activate(ignoringOtherApps: true)
        let response = ModalSession.run { alert.runModal() }
        if response == .alertFirstButtonReturn {
            defaults.set(true, forKey: acknowledgedKey)
        }
    }

    private static func text(_ key: String) -> String {
        NSLocalizedString(key, bundle: CompanionLocalization.bundle, comment: "First-use Keychain introduction")
    }
}
