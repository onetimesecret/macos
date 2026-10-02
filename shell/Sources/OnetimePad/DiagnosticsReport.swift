import AppKit
import CompanionKit
import Foundation

struct DiagnosticsReport: Sendable {
    let summary: String
    let details: String

    @MainActor
    static func capture(model: BackdropModel, shortcutStatus: String) -> DiagnosticsReport {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let revision = bundle.object(forInfoDictionaryKey: "OnetimePadSourceRevision") as? String ?? "unknown"
        let lane = bundle.object(forInfoDictionaryKey: "OnetimePadBuildLane") as? String ?? "unpackaged"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        let stance = model.stance == .raised ? "raised" : "resting"
        let altitude = BackdropAltitude.resolve(stance: model.stance, keyed: model.holdsKeys,
                                               pinned: model.pinned, keepsAbove: model.keepsAboveWhenInactive)
        let altitudeName: String
        switch altitude {
        case .desktop: altitudeName = "desktop"
        case .normal: altitudeName = "normal"
        case .floating: altitudeName = "floating"
        }
        let fields = [
            "OnetimePad \(version) (\(build))",
            "Source: \(revision); lane: \(lane)",
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion); \(architecture)",
            "Process uptime: \(max(0, Int(Date().timeIntervalSince(DiagnosticEvents.shared.startedAt)))) seconds",
            "Ambient panel: \(model.ambientPanelEnabled ? "on" : "off"); stance: \(stance)",
            "Editor: open=\(model.editorWindowOpen), visible=\(model.editorWindowOnScreen)",
            "Panel owns keyboard: \(model.holdsKeys)",
            "Pinned: \(model.pinned); keep above when inactive: \(model.keepsAboveWhenInactive)",
            "Expected panel altitude: \(altitudeName) (\(altitude.level.rawValue))",
            "Shortcut: \(shortcutStatus)",
            "Page layout: \(model.pages.showsTimeUnits ? "Timeline" : "Tabs")",
            "Sync enabled: \(model.pages.sync.enabled)"
        ]
        let summary = fields.joined(separator: "\n")
        let formatter = ISO8601DateFormatter()
        let trail = DiagnosticEvents.shared.snapshot().map { entry in
            formatter.string(from: entry.date) + " " + entry.kind.rawValue
                + (entry.status.map { " (OSStatus \($0))" } ?? "")
        }
        let details = "OnetimePad diagnostic report (format 1)\nCaptured: \(formatter.string(from: Date()))\n\n"
            + summary + "\n\nRecent events from this process (up to 100):\n"
            + (trail.isEmpty ? "No captured events." : trail.joined(separator: "\n"))
            + "\n\nThis report contains app/build metadata, selected settings, and typed event labels. "
            + "Window altitude is the model's expected value. Lockdown Mode and Keychain authorization choices are not detected.\n"
        return DiagnosticsReport(summary: summary, details: details)
    }
}
