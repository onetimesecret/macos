import AppKit
import SwiftUI
import XCTest

@testable import CompanionKit

@MainActor
final class PadCreateFormTests: XCTestCase {
    private final class Presentation: ObservableObject {
        var routesBinding: Binding<PadSettingsRoutes>?
        var anchors: [String: NSView] = [:]
        @Published var isEnabled = true

        var routes: PadSettingsRoutes {
            get { routesBinding!.wrappedValue }
            set { routesBinding!.wrappedValue = newValue }
        }
    }

    private struct Anchor: NSViewRepresentable {
        let register: (NSView) -> Void

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            register(view)
            return view
        }

        func updateNSView(_ view: NSView, context: Context) { register(view) }
    }

    private struct Surface: View {
        @ObservedObject var presentation: Presentation
        let model: PageModel
        @State private var routes = PadSettingsRoutes()

        var body: some View {
            VStack {
                Button("New Pad") { routes.beginCreating() }
                    .background(Anchor { presentation.anchors["New Pad"] = $0 })
                    .popover(isPresented: $routes.creation.isPresented, arrowEdge: .bottom) {
                        PadCreateForm(model: model, creation: $routes.creation)
                    }
                Spacer()
                Button("Outside") {}
                    .background(Anchor { presentation.anchors["Outside"] = $0 })
            }
            .padding(24)
            .frame(width: 360, height: 280)
            .disabled(!presentation.isEnabled)
            .onAppear { presentation.routesBinding = $routes }
        }
    }

    private struct Fixture {
        let model: PageModel
        let presentation: Presentation
        let window: NSWindow
    }

    private func waitFor(
        _ description: String, file: StaticString = #filePath, line: UInt = #line,
        until condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else {
                XCTFail(description, file: file, line: line)
                throw NSError(domain: "PadCreateFormTests", code: 1)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func mount() async throws -> Fixture {
        _ = NSApplication.shared
        let suite = "pad-create-native-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = isolatedModel(defaults: defaults)
        model.pads.isEnabled = true
        let presentation = Presentation()
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 360, height: 280),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Surface(presentation: presentation, model: model))
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in
            presentation.routesBinding?.wrappedValue.creation.isPresented = false
            window.orderOut(nil)
            window.close()
            window.contentView = nil
            presentation.routesBinding = nil
            presentation.anchors.removeAll()
        }
        try await waitFor("The fixture did not mount its presenter") {
            presentation.routesBinding != nil
                && presentation.anchors["New Pad"]?.window === window
                && presentation.anchors["Outside"]?.window === window
        }
        return Fixture(model: model, presentation: presentation, window: window)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func open(_ fixture: Fixture) async throws -> NSWindow {
        let existing = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        fixture.presentation.routes.beginCreating()
        var popover: NSWindow?
        try await waitFor("No native popover window appeared") {
            popover = NSApp.windows.first {
                !existing.contains(ObjectIdentifier($0)) && $0.isVisible && $0 !== fixture.window
                    && $0.contentView.map { view in
                        descendants(view).contains { ($0 as? NSTextField)?.isEditable == true }
                    } == true
            }
            return popover != nil
        }
        let window = try XCTUnwrap(popover)
        let field = try nameField(in: window)
        try await waitFor("The name field did not receive focus") { field.currentEditor() != nil }
        try await waitFor("The native creation form did not register its presentation") {
            fixture.model.hasPresentedPadCreation
        }
        return window
    }

    private func nameField(in window: NSWindow) throws -> NSTextField {
        let root = try XCTUnwrap(window.contentView)
        return try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextField }.first { $0.isEditable })
    }

    private func enter(_ name: String, in popover: NSWindow, fixture: Fixture) async throws {
        let field = try nameField(in: popover)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "The name field did not receive focus")
        editor.selectAll(nil)
        editor.insertText(name, replacementRange: editor.selectedRange())
        try await waitFor("Native typing did not update the draft") {
            fixture.presentation.routes.creation.draft == name
        }
    }

    private func key(_ character: String, code: UInt16, in window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character,
            isARepeat: false, keyCode: code))
        window.sendEvent(event)
    }

    private func click(_ title: String, in fixture: Fixture) throws {
        let target = try XCTUnwrap(fixture.presentation.anchors[title])
        let frame = target.convert(target.bounds, to: nil)
        let point = NSPoint(x: frame.midX, y: frame.midY)
        var events: [NSEvent] = []
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: fixture.window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            events.append(event)
        }
        events.forEach { NSApp.postEvent($0, atStart: false) }
        for (mask, phase) in [(NSEvent.EventTypeMask.leftMouseDown, "mouse-down"), (.leftMouseUp, "mouse-up")] {
            let queued = try XCTUnwrap(NSApp.nextEvent(
                matching: mask, until: Date().addingTimeInterval(1), inMode: .default, dequeue: true),
                "The posted \(phase) event for \(title) was not delivered to the fixture")
            NSApp.sendEvent(queued)
        }
    }

    func testNativeNameFieldFocusAndReturnCreateThePad() async throws {
        let fixture = try await mount()
        let popover = try await open(fixture)
        let field = try nameField(in: popover)
        let editor = try XCTUnwrap(popover.firstResponder as? NSTextView)
        XCTAssertTrue(editor.isFieldEditor)
        XCTAssertTrue(field.currentEditor() === editor)
        try await enter("Native Return", in: popover, fixture: fixture)
        XCTAssertEqual(fixture.presentation.routes.creation.draft, "Native Return")
        try key("\r", code: 36, in: popover)
        try await waitFor("Return did not dismiss the native form") {
            !fixture.presentation.routes.creation.isPresented && !popover.isVisible
                && !fixture.model.hasPresentedPadCreation
        }
        XCTAssertFalse(fixture.presentation.routes.creation.isPresented)
        XCTAssertEqual(fixture.presentation.routes.creation.draft, "")
        XCTAssertEqual(fixture.model.pads.activePad.name, "Native Return")
        XCTAssertFalse(popover.isVisible)
    }

    func testNativeEscapeClearsTheDraftAndDismissesTheForm() async throws {
        let fixture = try await mount()
        let popover = try await open(fixture)
        try await enter("Cancelled by Escape", in: popover, fixture: fixture)
        try key("\u{1b}", code: 53, in: popover)
        try await waitFor("Escape did not dismiss the native form") {
            !fixture.presentation.routes.creation.isPresented && !popover.isVisible
                && !fixture.model.hasPresentedPadCreation
        }
        XCTAssertFalse(fixture.presentation.routes.creation.isPresented)
        XCTAssertEqual(fixture.presentation.routes.creation.draft, "")
        XCTAssertEqual(fixture.model.pads.entries.count, 1)
        XCTAssertFalse(popover.isVisible)
    }

    func testNativeOutsideDismissalRetainsTheDraftForReopening() async throws {
        let fixture = try await mount()
        let popover = try await open(fixture)
        try await enter("Retained outside", in: popover, fixture: fixture)
        try click("Outside", in: fixture)
        try await waitFor("Clicking outside did not dismiss the native form") {
            !fixture.presentation.routes.creation.isPresented && !popover.isVisible
                && !fixture.model.hasPresentedPadCreation
        }
        XCTAssertFalse(popover.isVisible)
        XCTAssertFalse(fixture.presentation.routes.creation.isPresented)
        XCTAssertEqual(fixture.presentation.routes.creation.draft, "Retained outside")

        let reopened = try await open(fixture)
        let field = try nameField(in: reopened)
        XCTAssertEqual(field.stringValue, "Retained outside")
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        try await waitFor("The retained draft was not selected whole") {
            editor.selectedRange() == NSRange(location: 0, length: "Retained outside".utf16.count)
        }
    }

    func testDisablingThePresenterDismissesTheFormAndRetainsItsDraft() async throws {
        let fixture = try await mount()
        let popover = try await open(fixture)
        try await enter("Retained on rest", in: popover, fixture: fixture)
        fixture.presentation.isEnabled = false
        try await waitFor("A disabled presenter left the form visible") {
            !fixture.presentation.routes.creation.isPresented && !popover.isVisible
                && !fixture.model.hasPresentedPadCreation
        }
        XCTAssertEqual(fixture.presentation.routes.creation.draft, "Retained on rest")
        fixture.presentation.isEnabled = true
        let reopened = try await open(fixture)
        let field = try nameField(in: reopened)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(field.isEnabled)
        XCTAssertEqual(field.stringValue, "Retained on rest")
        try await waitFor("The draft restored after rest was not selected whole") {
            editor.selectedRange() == NSRange(location: 0, length: "Retained on rest".utf16.count)
        }
    }

    func testNativeAnchorClickClosesTheExistingForm() async throws {
        let fixture = try await mount()
        let popover = try await open(fixture)
        try await enter("Retained from anchor", in: popover, fixture: fixture)
        try click("New Pad", in: fixture)
        try await waitFor("Clicking the anchor did not dismiss the native form") {
            !fixture.presentation.routes.creation.isPresented && !popover.isVisible
                && !fixture.model.hasPresentedPadCreation
        }
        XCTAssertFalse(popover.isVisible)
        XCTAssertFalse(fixture.presentation.routes.creation.isPresented)
        XCTAssertEqual(fixture.presentation.routes.creation.draft, "Retained from anchor")
    }

    func testNativeEmptyReturnExplainsTheMissingNameWithoutDismissing() async throws {
        let fixture = try await mount()
        let popover = try await open(fixture)
        try key("\r", code: 36, in: popover)
        try await waitFor("Empty Return did not produce naming feedback") {
            fixture.presentation.routes.creation.message == CompanionL10n.string("pad.name.empty")
        }
        XCTAssertTrue(fixture.presentation.routes.creation.isPresented)
        XCTAssertTrue(popover.isVisible)
        XCTAssertEqual(fixture.model.pads.entries.count, 1)
        XCTAssertNotNil(try nameField(in: popover).currentEditor())
    }

    func testNativeFormSuspendsPadShortcutsAfterTheNameFieldResignsFocus() async throws {
        let fixture = try await mount()
        let popover = try await open(fixture)
        let field = try nameField(in: popover)
        XCTAssertTrue(popover.makeFirstResponder(nil))
        try await waitFor("The name field did not resign its editor") { field.currentEditor() == nil }
        XCTAssertTrue(fixture.model.hasPresentedPadCreation)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: popover.windowNumber, context: nil,
            characters: "0", charactersIgnoringModifiers: "0", isARepeat: false, keyCode: 29))
        XCTAssertTrue(PadShortcutMonitor.allows(number: 0, keymap: fixture.model.keymap))
        XCTAssertNil(PadShortcutMonitor.handle(
            event, model: fixture.model, surface: .panel, fallbackWindow: fixture.window,
            windows: [fixture.window, popover], isModal: false))
        try key("\u{1b}", code: 53, in: popover)
        try await waitFor("Dismissing the native form did not unregister it") {
            !fixture.presentation.routes.creation.isPresented && !popover.isVisible
                && !fixture.model.hasPresentedPadCreation
        }
    }

}
