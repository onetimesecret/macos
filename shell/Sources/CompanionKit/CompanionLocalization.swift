import Foundation

private final class LocalizationBundleToken {}

/// Packaging installs localizations directly in the app's Resources directory.
/// SwiftPM runs keep them in a sibling bundle. Avoid its generated accessor:
/// a missing translation must fall back to the English key, not fatalError.
public enum CompanionLocalization {
    public static let bundle: Bundle = {
        if Bundle.main.bundleURL.pathExtension == "app" { return .main }
        let home = Bundle(for: LocalizationBundleToken.self).bundleURL
        for directory in [home, home.deletingLastPathComponent()] {
            let url = directory.appendingPathComponent("OnetimePad_CompanionKit.bundle")
            if let bundle = Bundle(url: url) { return bundle }
        }
        return .main
    }()
}
