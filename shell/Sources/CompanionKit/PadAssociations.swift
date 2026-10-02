import AppKit

/// One transient previous application identity. No window inspection,
/// clipboard access, or application-switch history is retained.
@MainActor
final class PadApplicationContext {
    private nonisolated(unsafe) var observer: NSObjectProtocol?
    private var previousBundleID: String?
    private let arrivedFrom: (String) -> Void

    init(arrivedFrom: @escaping (String) -> Void) {
        self.arrivedFrom = arrivedFrom
        if let app = NSWorkspace.shared.frontmostApplication,
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousBundleID = app.bundleIdentifier
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let isSelf = app.processIdentifier == ProcessInfo.processInfo.processIdentifier
            let bundleID = app.bundleIdentifier
            let isRegular = app.activationPolicy == .regular
            MainActor.assumeIsolated {
                guard let self else { return }
                if isSelf {
                    if let previous = self.previousBundleID { self.arrivedFrom(previous) }
                } else if isRegular {
                    self.previousBundleID = bundleID
                }
            }
        }
    }
    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

extension PageModel {
    public var runningAssociationApplications: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.bundleIdentifier != nil
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
    public func activateAssociatedApplication(_ bundleID: String) {
        guard let app = runningAssociationApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
            flash("This associated application is not running.")
            return
        }
        if !app.activate(options: [.activateIgnoringOtherApps]) {
            flash("The associated application could not be activated.")
        }
    }
    public func addApplication(_ bundleID: String, toPad id: UUID) {
        guard runningAssociationApplications.contains(where: { $0.bundleIdentifier == bundleID }) else { return }
        pads.addApplication(bundleID, to: id)
    }
    public func removeApplication(_ bundleID: String, fromPad id: UUID) {
        pads.removeApplication(bundleID, from: id)
    }
    public func addFolder(toPad id: UUID) {
        guard pads.isEnabled, !FormFactor.runningUnderTests else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Associate"
        let response = ModalSession.run { panel.runModal() }
        guard response == .OK else { return }
        for url in panel.urls {
            if !pads.addFolder(url.path, to: id) {
                flash("This folder is already associated with a pad.")
            }
        }
    }
    public func removeFolder(_ path: String, fromPad id: UUID) {
        pads.removeFolder(path, from: id)
    }
}
