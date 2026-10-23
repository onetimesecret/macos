import CompanionKit

/// Recognized packaging identifiers for executable startup.
enum AppLaunchIdentity {
    static func accepts(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        return [FormFactor.backdropBundleIdentifier, FormFactor.localBundleIdentifier,
                FormFactor.devBundleIdentifier].contains(identifier)
    }
}
