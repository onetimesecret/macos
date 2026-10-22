import CompanionKit

/// Validate the bundle before constructing a default model or resolving its stores.
enum AppLaunchIdentity {
    static func accepts(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        return [FormFactor.backdropBundleIdentifier, FormFactor.localBundleIdentifier,
                FormFactor.devBundleIdentifier].contains(identifier)
    }
}
