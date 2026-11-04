import AppKit
import SwiftUI
import XCTest

@testable import CompanionKit

@MainActor
final class PadWorkspaceTests: XCTestCase {
    private final class Mounts {
        var created = 0
        weak var editor: NSView?
    }

    private final class EditorProbeView: NSView {
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.textBackgroundColor.setFill()
            bounds.fill()
            let title = "Design notes" as NSString
            title.draw(at: NSPoint(x: 28, y: 32), withAttributes: [
                .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ])
            let text = "A quiet place for the work in progress.\n\nThe editor stays beside the pad details." as NSString
            text.draw(in: NSRect(x: 28, y: 82, width: max(0, bounds.width - 56), height: 160),
                      withAttributes: [.font: NSFont.systemFont(ofSize: 14),
                                       .foregroundColor: NSColor.secondaryLabelColor])
        }
    }

    private struct EditorProbe: NSViewRepresentable {
        let mounts: Mounts

        func makeNSView(context: Context) -> NSView {
            mounts.created += 1
            let editor = EditorProbeView()
            mounts.editor = editor
            return editor
        }

        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    private final class InspectorState: ObservableObject {
        @Published var routes = PadInspectorRoutes()
    }

    private struct InspectorHost: View {
        @ObservedObject var model: PageModel
        @ObservedObject var state: InspectorState

        var body: some View {
            PadInspectorView(model: model, pads: model.pads, routes: $state.routes, showsNewPad: false)
        }
    }

    private func model() throws -> PageModel {
        let suite = "pad-workspace-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let model = PageModel(formFactor: .backdrop, defaults: defaults,
            seams: .init(stateDirectory: directory, client: .ephemeral(tag: suite), saveDebounce: 3_600))
        model.showsTimeUnits = true
        for name in ["GameCore", "OnetimeSecret", "Docs", "Design notes"] {
            _ = try XCTUnwrap(model.createPad(named: name))
        }
        for index in 0..<20 {
            XCTAssertTrue(model.pads.addFolder(
                "/Projects/research/long-parent-directory-for-context/topic-\(index)/documentation", to: model.pads.activeID))
        }
        model.pads.addApplication("org.example.Design", to: model.pads.activeID)
        return model
    }

    private func host<Content: View>(_ content: Content, width: CGFloat) -> (NSWindow, NSHostingView<Content>) {
        _ = NSApplication.shared
        let size = NSSize(width: width, height: 520)
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.appearance = NSAppearance(named: .darkAqua)
        addTeardownBlock { @MainActor in
            window.orderOut(nil)
            window.close()
            window.contentView = nil
        }
        return (window, hosting)
    }

    private func settle(_ host: NSView) async {
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        host.layoutSubtreeIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func testInspectorAdaptsFromDetailsToListToEditorAndDetails() {
        let narrow = PadWorkspaceLayout(width: 360, inspecting: true)
        XCTAssertFalse(narrow.showsPadList)
        XCTAssertFalse(narrow.showsEditor)
        XCTAssertNil(narrow.inspectorWidth)
        let medium = PadWorkspaceLayout(width: 560, inspecting: true)
        XCTAssertTrue(medium.showsPadList)
        XCTAssertFalse(medium.showsEditor)
        XCTAssertNil(medium.inspectorWidth)
        let wide = PadWorkspaceLayout(width: 900, inspecting: true)
        XCTAssertTrue(wide.showsPadList)
        XCTAssertTrue(wide.showsEditor)
        XCTAssertGreaterThan(wide.inspectorWidth ?? 0, 250)
        for width: CGFloat in [360, 560, 900] {
            let editing = PadWorkspaceLayout(width: width, inspecting: false)
            XCTAssertTrue(editing.showsEditor)
            XCTAssertFalse(editing.showsPadList)
            XCTAssertNil(editing.inspectorWidth)
        }
    }

    func testLongFolderListsScrollWithinNarrowAndWideWindows() async throws {
        let model = try model()
        model.showPadInspector()
        let mounts = Mounts()
        let (window, hosting) = host(
            PadWorkspaceView(model: model) { EditorProbe(mounts: mounts) }, width: 360)
        for width: CGFloat in [360, 640, 1_000] {
            window.setContentSize(NSSize(width: width, height: 520))
            await settle(hosting)
            XCTAssertEqual(hosting.bounds.width, width, accuracy: 1)
            let scrolls = descendants(hosting).compactMap { $0 as? NSScrollView }
            let inspector = try XCTUnwrap(scrolls.max {
                ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
            })
            let frame = hosting.convert(inspector.bounds, from: inspector)
            XCTAssertGreaterThanOrEqual(frame.minX, -1, "inspector overflow at \(width)")
            XCTAssertLessThanOrEqual(frame.maxX, width + 1, "inspector overflow at \(width)")
            XCTAssertGreaterThan(inspector.contentView.bounds.width, 250)
            XCTAssertGreaterThan(inspector.contentView.bounds.height, 250)
            XCTAssertGreaterThan(try XCTUnwrap(inspector.documentView).frame.height,
                                 inspector.contentView.bounds.height + 200)
            XCTAssertEqual(scrolls.count, width >= 560 ? 2 : 1)
        }
        if let path = ProcessInfo.processInfo.environment["PAD_INSPECTOR_SNAPSHOT_PATH"] {
            for folder in model.pads.activePad.folderPaths {
                model.pads.removeFolder(folder, from: model.pads.activeID)
            }
            for folder in ["/Projects/OnetimeSecret/macos", "/Projects/OnetimeSecret/macos/docs",
                           "/Projects/OnetimeSecret/macos/tools"] {
                XCTAssertTrue(model.pads.addFolder(folder, to: model.pads.activeID))
            }
            window.orderFront(nil)
            let destination = URL(fileURLWithPath: path)
            let compact = destination.deletingPathExtension().appendingPathExtension("compact.png")
            for (width, output): (CGFloat, URL) in [(1_000, destination), (640, compact)] {
                window.setContentSize(NSSize(width: width, height: 520))
                await settle(hosting)
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output)
            }
        }
    }

    func testEditorRemainsMountedAcrossInspectorAndWindowSizeChanges() async throws {
        let model = try model()
        let mounts = Mounts()
        let (window, hosting) = host(
            PadWorkspaceView(model: model) { EditorProbe(mounts: mounts) }, width: 1_000)
        await settle(hosting)
        let editor = try XCTUnwrap(mounts.editor)
        XCTAssertEqual(mounts.created, 1)
        XCTAssertGreaterThan(editor.bounds.width, 400)
        for width: CGFloat in [1_000, 640, 360, 1_000] {
            model.showPadInspector()
            window.setContentSize(NSSize(width: width, height: 520))
            await settle(hosting)
            XCTAssertTrue(mounts.editor === editor)
            XCTAssertEqual(mounts.created, 1, "editor remounted at \(width)")
            if width >= 900 { XCTAssertGreaterThan(editor.bounds.width, 300) }
            else { XCTAssertLessThanOrEqual(editor.bounds.width, 1) }
            model.isPadInspectorVisible = false
            await settle(hosting)
            XCTAssertTrue(mounts.editor === editor)
            XCTAssertEqual(mounts.created, 1)
            XCTAssertGreaterThan(editor.bounds.width, 150)
        }
    }

    func testInspectorRenameUsesAnInlineFieldAndReturnsToTheName() async throws {
        let model = try model()
        let state = InspectorState()
        let (_, hosting) = host(InspectorHost(model: model, state: state), width: 360)
        await settle(hosting)
        state.routes.beginRename(model.pads.activePad)
        await settle(hosting)
        XCTAssertEqual(descendants(hosting).compactMap { $0 as? NSTextField }.filter(\.isEditable).count, 1)
        state.routes.rename.edit("Design decisions")
        state.routes.rename.commit(in: model)
        await settle(hosting)
        XCTAssertEqual(model.pads.activePad.name, "Design decisions")
        XCTAssertFalse(state.routes.rename.isOpen)
        XCTAssertTrue(descendants(hosting).compactMap { $0 as? NSTextField }.filter(\.isEditable).isEmpty)
    }
}
