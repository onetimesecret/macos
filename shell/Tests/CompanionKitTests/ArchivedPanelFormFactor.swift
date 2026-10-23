import CompanionKit

extension FormFactor {
    // ADR-0014 archived this executable; legacy-store comparisons use explicit test data.
    static var panel: FormFactor {
        FormFactor(
            credentialService: panelBundleIdentifier,
            stateDirectory: "\(panelBundleIdentifier).noindex",
            loggerSubsystem: panelBundleIdentifier
        )
    }
}
