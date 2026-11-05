import AppKit
import CompanionCore
import SwiftUI
import XCTest

@testable import CompanionKit
@testable import OnetimePad

/// The card fades the timeline split as one piece; a stance change under that fade keeps the page's
/// editor, the split and the rail's width.
@MainActor
final class TimelineSplitFadeTests: XCTestCase {
    /// The card's arrangement: the split's range follows the stance, and one fade covers the split.
    private struct FadedSplit: View {
        @ObservedObject var model: PageModel
        let raised: Bool

        var body: some View {
            TimelineSplitView(
                showsTimeline: true, resizable: raised,
                railWidth: model.timelineWidth, onRailResize: model.recordTimelineWidth,
                leftMouseIsDown: { false }
            ) {
                TimeRailView(model: model, readOnly: !raised)
            } content: {
                PageContentView(model: model, readOnly: !raised, emptyHint: "", showsExpandControl: false)
            }
            .stanceFaded(raised: raised, animation: .easeInOut(duration: 0.16))
            .environment(\.presentationSurface, model.owner)
        }
    }

    private func makeModel() throws -> PageModel {
        let tag = "timeline-fade-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(tag)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: tag))
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: tag)
            try? FileManager.default.removeItem(at: directory)
        }
        companion_init()
        let handle = try XCTUnwrap(tag.withCString { companion_new_ephemeral($0) })
        let model = PageModel(formFactor: .backdrop, defaults: defaults,
            seams: .init(stateDirectory: directory, client: CompanionClient(adopting: handle)))
        model.newPage()
        model.showsTimeUnits = true
        return model
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
    }

    private func layout(_ host: NSView) {
        for _ in 0..<2 {
            host.layoutSubtreeIfNeeded()
            drainMainQueue()
        }
        host.layoutSubtreeIfNeeded()
    }

    func testAStanceChangeUnderTheFadeKeepsTheEditorTheSplitAndTheWidth() throws {
        let model = try makeModel()
        model.recordTimelineWidth(180)
        let host = NSHostingView(rootView: FadedSplit(model: model, raised: true))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        layout(host)

        let editor = try XCTUnwrap(descendants(InkTextView.self, in: host).first)
        let split = try XCTUnwrap(descendants(NSSplitView.self, in: host).first)
        XCTAssertEqual(split.arrangedSubviews[0].frame.width, 180, accuracy: 2, "the control: the rail is placed")

        for raised in [false, true, false, true] {
            host.rootView = FadedSplit(model: model, raised: raised)
            layout(host)
            XCTAssertTrue(descendants(InkTextView.self, in: host).first === editor, "the stance remounted the editor")
            XCTAssertTrue(descendants(NSSplitView.self, in: host).first === split, "the stance remounted the split")
            XCTAssertEqual(split.arrangedSubviews[0].frame.width, 180, accuracy: 2, "the rail moved with the stance")
        }
        XCTAssertEqual(model.timelineWidth, 180, accuracy: 0.5, "a stance change was recorded")
    }
}
