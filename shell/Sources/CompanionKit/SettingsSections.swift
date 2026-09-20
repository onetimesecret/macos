import AppKit
import ServiceManagement
import SwiftUI

/// Launch at login, through `SMAppService.mainApp` (macOS 13+). The
/// registration belongs to exactly one bundle: the installed copy in
/// /Applications. A dev build running from .build/ or dist/ must never
/// claim the login item, or login would resurrect whichever build ran
/// Settings last.
///
/// `SMAppService.mainApp` is per-bundle by construction, so the two form
/// factors register and unregister independently even though they share
/// this code — each one's `mainApp` is its own bundle.
public enum LaunchAtLogin {
    /// The guard, as a pure decision on the bundle's path so the rule
    /// is testable without a bundle: only a copy installed under
    /// /Applications may register.
    public nonisolated static func pathMayRegister(_ bundlePath: String) -> Bool {
        bundlePath.hasPrefix("/Applications/")
    }

    public static var mayRegister: Bool {
        pathMayRegister(Bundle.main.bundleURL.path)
    }

    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registration can land in `.requiresApproval`: macOS holds the
    /// item disabled until the user approves it in System Settings.
    public static var awaitingApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    public static func set(enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// The caption a settings section carries above its rows. Every
/// section in the three forms wears the same small secondary text, so
/// the style lives once rather than beside each `Section`.
private struct SettingsCaption: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// The General tab: what this app and its surface do, as opposed to
/// where a conceal goes (Connection) or how pages travel (Sync). The
/// toggles here bind straight to the model, so the tab has no Save
/// button; each flip is its own save.
///
/// The surface's own setting, where the card sits, is the one row the
/// shared code cannot draw itself: the geometry belongs to the form
/// factor's model, so the window hands in a closure and the section
/// appears only when one is given.
public struct GeneralSettingsView: View {
    @ObservedObject var model: PageModel

    /// What the login toggle's caption promises to bring back. The
    /// panel's presence was a menu-bar item; the backdrop's is the
    /// surface itself.
    private let loginPresence: String

    /// Whether this settings screen is one that may carry the capture
    /// opt-out at all, i.e. whether the surrounding target honours it.
    /// Separate from `PageModel.captureOptOutOffered`, which decides
    /// whether this process offers the switch to anyone.
    private let offersCaptureToggle: Bool

    /// Returns the surface to its default place and size, when the
    /// form factor has such a thing to return.
    private let resetSurface: (() -> Void)?

    /// The keep-above preference the surface offers alongside the pin
    /// (ADR-0032). Nil where the form factor has no such preference to
    /// bind (the panel), which hides the row and keeps this shared
    /// form drawing the same shape for both callers.
    private let keepsAbove: Binding<Bool>?

    /// ADR-0033's ambient panel preference. Default on, persisted
    /// beside Pin. Nil hides the row, as it does for `keepsAbove`.
    private let ambientPanelEnabled: Binding<Bool>?

    public init(
        model: PageModel,
        loginPresence: String,
        offersCaptureToggle: Bool = true,
        resetSurface: (() -> Void)? = nil,
        keepsAbove: Binding<Bool>? = nil,
        ambientPanelEnabled: Binding<Bool>? = nil
    ) {
        self.model = model
        self.loginPresence = loginPresence
        self.offersCaptureToggle = offersCaptureToggle
        self.resetSurface = resetSurface
        self.keepsAbove = keepsAbove
        self.ambientPanelEnabled = ambientPanelEnabled
    }

    @State private var confirmingLedgerClear = false
    @State private var launchAtLogin = false
    @State private var loginStatus: String?

    /// The family field in draft, committed on ⏎ and when focus leaves.
    /// Per-keystroke application would restyle the page through every
    /// prefix of "JetBrains Mono", most of which name nothing, and flash
    /// the fallback face while the user is still typing.
    @State private var fontFamilyDraft = ""
    @FocusState private var fontFamilyFocused: Bool

    public var body: some View {
        Form {
            if let resetSurface {
                Section {
                    if let keepsAbove {
                        Toggle(
                            "Keep OnetimePad above other apps when switching away",
                            isOn: keepsAbove
                        )
                    }
                    if let ambientPanelEnabled {
                        Toggle(
                            "Show the ambient panel",
                            isOn: ambientPanelEnabled
                        )
                    }
                    Button("Reset to default position and size", action: resetSurface)
                } header: {
                    Text("Surface")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if ambientPanelEnabled != nil {
                            SettingsCaption(
                                "The card that rests at the desktop and rises on ⌃⌥Space. Off shows only the primary editor window; the hotkey and the menu bar item open that window instead."
                            )
                        }
                        if keepsAbove != nil {
                            SettingsCaption(
                                "Pin keeps the card above regardless. A click outside the card still rests it."
                            )
                        }
                        SettingsCaption(
                            "Returns the card to its original place and size. Takes effect immediately."
                        )
                    }
                }
            }
            Section {
                TextField("Prose font", text: $fontFamilyDraft, prompt: Text("System Monospaced"))
                    .focused($fontFamilyFocused)
                    .onSubmit(commitFontFamily)
                    .onChange(of: fontFamilyFocused) { focused in
                        if !focused { commitFontFamily() }
                    }
                HStack {
                    TextField("Size", value: $model.fontSize, format: .number.precision(.fractionLength(0)))
                        .frame(maxWidth: 80)
                    Stepper(
                        "Size",
                        value: $model.fontSize,
                        in: Double(InkStyle.Typeface.sizeRange.lowerBound)...Double(InkStyle.Typeface.sizeRange.upperBound),
                        step: 1
                    )
                    .labelsHidden()
                    Spacer()
                }
                if let fontStatus {
                    Text(fontStatus)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.emberText)
                }
            } header: {
                SettingsCaption(typeCaption)
            }
            Section {
                Toggle("Wrap long lines", isOn: $model.wrapsLines)
            } header: {
                SettingsCaption(
                    "What the page does with a line wider than the card. Off lets lines run on and the page scrolls sideways. ⌥Z flips it while you write, and whichever way you left it is how the page opens."
                )
            }

            Section {
                Picker("Organize pages by", selection: $model.showsTimeUnits) {
                    Text("Slots").tag(false)
                    Text("Days (time tabs) · prototype").tag(true)
                }
                .pickerStyle(.segmented)
            } header: {
                SettingsCaption(Self.pageOrganizationCaption)
            }
            Section {
                Picker("Show pages", selection: $model.showsPagesDownSide) {
                    Text("Along the bottom").tag(false)
                    Text("Down the side").tag(true)
                }
                .pickerStyle(.segmented)
            } header: {
                SettingsCaption(Self.pagePlacementCaption)
            }
            // The rounding switch and the time patterns are about
            // time, so they appear only under the Days choice (D-26).
            if model.showsTimeUnits {
                Section {
                    Toggle("Round a page's deadline up to the hour, or to midnight", isOn: $model.snapsToBoundaries)
                } header: {
                    SettingsCaption(
                        "A rung names a duration; this lets the deadline land where the clock does. Under a day it rounds up to the next whole hour, from a day up to the next midnight, and never by more than a day. Pages already counting down keep the deadline they have."
                    )
                }
                Section {
                    TextField("Time on a page", text: stampBinding(\.short), prompt: Text("HH:mm"))
                    TextField(
                        "When two pages share a minute", text: stampBinding(\.fine),
                        prompt: Text("HH:mm:ss"))
                } header: {
                    SettingsCaption(Self.stampFormatCaption)
                }
            }
            Section {
                Toggle("Start at login", isOn: loginBinding)
                    .disabled(!LaunchAtLogin.mayRegister)
                if let loginStatus {
                    Text(loginStatus)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.emberText)
                }
            } header: {
                SettingsCaption(loginCaption)
            }
            Section {
                Toggle("Show versions in menu", isOn: $model.showsVersionsInMenu)
            } header: {
                SettingsCaption(
                    "Adds the app build and linked Rust component versions to the menu-bar menu. Technical versions remain available in About."
                )
            }
            if offersCaptureToggle, PageModel.captureOptOutOffered {
                Section {
                    Toggle("Allow screenshots of the surface", isOn: $model.allowCapture)
                } header: {
                    SettingsCaption(captureCaption)
                }
            }
            // Hidden with the rest of the ledger's entry points (issue
            // #78), except while the surface is standing there telling
            // the user to come here and clear the ledger. That banner
            // names this button as the one way out of a ledger that
            // will not open, and hiding the button it names would make
            // the instruction a dead end.
            //
            // The flag is `@Published`, so the section arrives with the
            // banner and leaves the moment the clear lands: the
            // disappearance is the receipt.
            if HiddenUI.showsLedgerClear(ledgerRestoreRefused: model.ledgerRestoreRefused) {
                Section {
                    Button("Clear the ledger", role: .destructive) { confirmingLedgerClear = true }
                        .confirmationDialog(
                            "Clear the ledger?",
                            isPresented: $confirmingLedgerClear,
                            titleVisibility: .visible
                        ) {
                            Button("Clear the ledger", role: .destructive) { clearLedger() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Every record goes, and there is no undo. Pages and sealed chips are untouched.")
                        }
                } header: {
                    SettingsCaption(
                        "The ledger records what the app did with each item: never the content, but page names, and those are often the secret's label. It survives restarts and keeps 90 days."
                    )
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            fontFamilyDraft = model.fontFamily
        }
    }

    /// The face and size the page is set in, named the way an editor
    /// names its buffer font: a family as the system spells it, and a
    /// size in points. The caption says what an empty field means and
    /// what an unknown name does, since both are silent otherwise.
    private var typeCaption: String {
        "The page's face and size. Name a family as the system does (Menlo, JetBrains Mono); "
            + "leave it empty for the system monospaced font. A family that is not installed "
            + "is kept as typed, and the page uses the system font until it is. Sizes run from "
            + "\(Int(InkStyle.Typeface.sizeRange.lowerBound)) to \(Int(InkStyle.Typeface.sizeRange.upperBound)) points. "
            + "Headings scale with the size."
    }

    /// The one thing the field cannot show on its own: that the family
    /// it holds is not one this Mac can draw.
    private var fontStatus: String? {
        model.typeface.isInstalled ? nil : "\(model.fontFamily) is not installed; using the system monospaced font"
    }

    private func commitFontFamily() {
        let family = fontFamilyDraft.trimmingCharacters(in: .whitespaces)
        fontFamilyDraft = family
        guard family != model.fontFamily else { return }
        model.fontFamily = family
    }

    /// The two axes' captions say both what changes and what it costs.
    /// User-facing copy never exposes the components' code names.
    static let pageOrganizationCaption: String =
        "Slots are pages you name and close yourself. Days is a prototype that groups live "
            + "pages by the day they were written, newest first; lines always wrap and older "
            + "blank pages are counted rather than drawn. Changing this moves no content and "
            + "writes nothing new to disk."

    static let pagePlacementCaption: String =
        "Along the bottom keeps the page at full width and may scroll sideways. Down the side "
            + "keeps longer names readable but takes 110 points from the page. Placement does "
            + "not change how pages are grouped or stored."

    /// The section only exists when the switch is offered, so the
    /// caption's job is to say why this build has one and how long it
    /// lasts, not to explain its absence.
    private var captureCaption: String {
        #if DEBUG
        return "Debug build: lifts the screen-capture exclusion until the app quits."
        #else
        return "Shown because this app was launched with COMPANION_ALLOW_CAPTURE. It lifts the screen-capture exclusion until the app quits, and an ordinary launch offers no such switch."
        #endif
    }

    /// What the two time patterns cost and do, in the caption's own
    /// words (D-26).
    static let stampFormatCaption =
        "How a page's birth time reads beside its day, on the rail and in the gutter. The day's words carry the date, so the time stands alone; two pages born the same minute take the second pattern so they read apart. Unicode date patterns: HH:mm, HH:mm:ss, h:mm a. Empty means the standard one."

    /// One field of the stamp format, edited in place. An empty
    /// pattern is kept as typed and read as the standard one.
    private func stampBinding(
        _ keyPath: WritableKeyPath<StreamNavigator.StampFormat, String>
    ) -> Binding<String> {
        Binding(
            get: { model.stampFormat[keyPath: keyPath] },
            set: { model.stampFormat[keyPath: keyPath] = $0 }
        )
    }

    /// The toggle speaks to `SMAppService` directly; a refused
    /// registration reverts the switch to the system's actual state
    /// rather than showing a wish as a fact.
    private var loginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { wanted in
                do {
                    try LaunchAtLogin.set(enabled: wanted)
                    launchAtLogin = wanted
                    loginStatus = wanted && LaunchAtLogin.awaitingApproval
                        ? "waiting for approval under System Settings, Login Items"
                        : nil
                } catch {
                    launchAtLogin = LaunchAtLogin.isEnabled
                    loginStatus = "macOS refused: \(error.localizedDescription)"
                }
            }
        )
    }

    private var loginCaption: String {
        LaunchAtLogin.mayRegister
            ? "Brings \(loginPresence) back when you log in."
            : "Only the installed copy in /Applications can register at login, so a dev build never claims the login item."
    }

    /// The clear is in memory core-side, so the model marks the store
    /// dirty and the debounced write is what puts an empty ledger over
    /// the file. Nothing is reported back: an empty ledger is the
    /// receipt.
    private func clearLedger() {
        model.clearLedger()
    }
}

/// Code typography and source presentation. Font and highlighting are
/// display-only; detector-backed controls stay behind their release gate.
public struct CodeSettingsView: View {
    @ObservedObject var model: PageModel

    @State private var codeFontFamilyDraft = ""
    @FocusState private var codeFontFamilyFocused: Bool

    public init(model: PageModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section {
                TextField(
                    "Code font",
                    text: $codeFontFamilyDraft,
                    prompt: Text("System Monospaced")
                )
                .focused($codeFontFamilyFocused)
                .onSubmit(commitCodeFontFamily)
                .onChange(of: codeFontFamilyFocused) { focused in
                    if !focused { commitCodeFontFamily() }
                }
                if let codeFontStatus {
                    Text(codeFontStatus)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.emberText)
                }
            } header: {
                SettingsCaption(
                    "Fenced code uses this fixed-width family at the page's text size. Leave it empty for System Monospaced."
                )
            }

            Section {
                Toggle("Syntax highlighting", isOn: $model.syntaxHighlightingEnabled)
            } header: {
                SettingsCaption(
                    "Colors recognized source tokens. Turning it off keeps the code font and fence presentation."
                )
            }

            Section {
                Picker("Preview rendering", selection: $model.previewRendering) {
                    Text("Focused page only").tag(PreviewRenderingScope.focusedOnly)
                    Text("All pages").tag(PreviewRenderingScope.allPages)
                    Text("Never").tag(PreviewRenderingScope.never)
                }
                .pickerStyle(.inline)
            } header: {
                SettingsCaption(
                    "When to apply markdown formatting and syntax highlighting."
                )
            }

            if PageModel.languageDetectionFeaturesAvailable {
                Section {
                    Toggle("Language detection", isOn: $model.languageDetectionEnabled)
                    Toggle(
                        "Automatically fence detected code",
                        isOn: $model.automaticallyFencePastes
                    )
                    .disabled(!model.languageDetectionEnabled)
                    .accessibilityHint(
                        "Requires Language detection. Applies to future pastes only. Hold Option while pasting to bypass once."
                    )
                } header: {
                    SettingsCaption(
                        "Detection suggests a source language on request. Autofencing additionally wraps eligible whole-line pastes when detection returns a language; existing text is unchanged."
                    )
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { codeFontFamilyDraft = model.codeFontFamily }
    }

    private var codeFontStatus: String? {
        guard !model.typeface.codeFamilyIsUsable else { return nil }
        return "\(model.codeFontFamily) is not an installed fixed-width family; using System Monospaced"
    }

    private func commitCodeFontFamily() {
        let family = codeFontFamilyDraft.trimmingCharacters(in: .whitespaces)
        codeFontFamilyDraft = family
        guard family != model.codeFontFamily else { return }
        model.codeFontFamily = family
    }
}

/// The Connection tab: where a conceal goes and who it goes as. The
/// token field is write-only by design: what is stored can never be
/// read back out of the Keychain into this UI, and the placeholder
/// just says one is held.
///
/// Unlike the General tab, this one holds its fields in draft until
/// Save, because a half-typed server URL is not a setting anyone wants
/// applied, and Test saves first so it tests what will be kept.
public struct ConnectionSettingsView: View {
    @ObservedObject var model: PageModel

    public init(model: PageModel) {
        self.model = model
    }

    @State private var serverUrl = ""
    @State private var extid = ""
    @State private var token = ""
    @State private var shareDomain = ""
    @State private var status: String?
    @State private var statusIsError = false
    @State private var testing = false
    @State private var confirmingClear = false

    public var body: some View {
        Form {
            Section {
                TextField("Server URL", text: $serverUrl, prompt: Text("https://eu.onetimesecret.com"))
                TextField("Share domain", text: $shareDomain, prompt: Text("optional; defaults to the server's host"))
            } header: {
                SettingsCaption("Where a conceal goes, over https only.")
            }
            Section {
                TextField("Organization extid", text: $extid, prompt: Text("empty for guest conceals"))
                SecureField("API token", text: $token, prompt: Text(tokenPrompt))
                if model.connection?.hasToken == true {
                    Button("Clear stored token", role: .destructive) { confirmingClear = true }
                        .confirmationDialog(
                            "Clear the stored API token?",
                            isPresented: $confirmingClear,
                            titleVisibility: .visible
                        ) {
                            Button("Clear token", role: .destructive) { clearToken() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Conceals fall back to guest links until you enter a new token.")
                        }
                }
            } header: {
                SettingsCaption("The token goes straight to the Keychain and is never shown again.")
            }
            HStack {
                Button("Test") { test() }
                    .disabled(testing)
                if testing {
                    ProgressView().controlSize(.small)
                }
                if let status {
                    Text(status)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(statusIsError ? Color.emberText : Color.secondary)
                }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    private var tokenPrompt: String {
        (model.connection?.hasToken ?? false) ? "•••• stored in the Keychain" : "paste your API token"
    }

    private func load() {
        guard let connection = model.connection else { return }
        serverUrl = connection.serverUrl
        extid = connection.extid
        shareDomain = connection.shareDomain
    }

    private func save() {
        // An untouched token field keeps the stored token (nil through
        // the seam); typed text replaces it. Deleting is explicit:
        // clear the extid and the token is unused either way.
        let accepted = model.saveConnection(
            serverUrl: serverUrl.trimmingCharacters(in: .whitespaces),
            shareDomain: shareDomain.trimmingCharacters(in: .whitespaces),
            extid: extid.trimmingCharacters(in: .whitespaces),
            token: token.isEmpty ? nil : token
        )
        token = ""
        statusIsError = !accepted
        status = Self.saveStatus(accepted: accepted)
    }

    /// The two words a save can end on. The refusal names the one rule
    /// the core applies to the URL (D-24), and it lives here rather
    /// than inline in `save()` so a test can hold it to the record.
    nonisolated static func saveStatus(accepted: Bool) -> String {
        accepted ? "saved" : "refused: the server URL must be https://…"
    }

    private func clearToken() {
        let cleared = model.clearToken()
        token = ""
        statusIsError = !cleared
        status = cleared ? "token cleared" : "could not clear the token"
    }

    private func test() {
        save()
        guard !statusIsError else { return }
        testing = true
        status = nil
        model.testConnection { outcome in
            testing = false
            statusIsError = !outcome.ok
            status = outcome.ok ? "the server answers" : (outcome.error ?? "test failed")
        }
    }
}

/// The Sync tab: `SyncSettingsSection` given a form of its own. The
/// section already draws the switch, the sign-in and the device roster
/// (issue #102); all this adds is the grouped frame the other two tabs
/// wear, so the three read as one window.
public struct SyncSettingsView: View {
    private let sync: SyncController

    public init(sync: SyncController) {
        self.sync = sync
    }

    public var body: some View {
        Form {
            SyncSettingsSection(sync: sync)
        }
        .formStyle(.grouped)
    }
}
