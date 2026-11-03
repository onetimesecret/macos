import AppKit
import SwiftUI
import XCTest

@testable import CompanionKit

@MainActor
final class TimelineSplitViewTests: XCTestCase {
    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
    }

    func testNativeDividerResizesTheRailAndPageAndSurvivesUpdates() throws {
        let suite = "timeline-split-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = isolatedModel(defaults: defaults)
        model.newPage()
        model.showsTimeUnits = true
        func root(showsTimeline: Bool = true) -> AnyView {
            AnyView(TimelineSplitView(showsTimeline: showsTimeline) {
                TimeRailView(model: model, readOnly: false)
            } content: {
                PageContentView(model: model, emptyHint: "", showsExpandControl: false)
            }.environment(\.presentationSurface, model.owner))
        }
        let host = NSHostingView(rootView: root())
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        func layout() {
            host.layoutSubtreeIfNeeded()
            drainMainQueue()
            host.layoutSubtreeIfNeeded()
        }
        layout()
        let split = try XCTUnwrap(descendants(NSSplitView.self, in: host).first)
        XCTAssertTrue(split.isVertical)
        XCTAssertEqual(split.dividerStyle, .thin)
        XCTAssertEqual(split.arrangedSubviews.count, 2)
        XCTAssertEqual(split.arrangedSubviews[0].frame.width, TimeRailView.width, accuracy: 2)
        let editor = try XCTUnwrap(descendants(InkTextView.self, in: host).first)
        let pageWidth = split.arrangedSubviews[1].frame.width

        split.setPosition(180, ofDividerAt: 0)
        layout()
        XCTAssertEqual(split.arrangedSubviews[0].frame.width, 180, accuracy: 2)
        XCTAssertEqual(pageWidth - split.arrangedSubviews[1].frame.width, 70, accuracy: 2)
        XCTAssertTrue(descendants(InkTextView.self, in: host).first === editor)

        model.pads.isEnabled = true
        host.rootView = root()
        layout()
        XCTAssertEqual(split.arrangedSubviews[0].frame.width, 180, accuracy: 2)

        split.setPosition(0, ofDividerAt: 0)
        layout()
        XCTAssertEqual(split.arrangedSubviews[0].frame.width, TimeRailView.width, accuracy: 2)

        split.setPosition(500, ofDividerAt: 0)
        layout()
        XCTAssertEqual(split.arrangedSubviews[0].frame.width, 280, accuracy: 2)
        XCTAssertTrue(descendants(InkTextView.self, in: host).first === editor)

        host.frame.size.width = 720
        layout()
        XCTAssertEqual(split.arrangedSubviews[0].frame.width, 280, accuracy: 2)

        host.rootView = root(showsTimeline: false)
        layout()
        XCTAssertEqual(split.arrangedSubviews.count, 1)
        XCTAssertGreaterThan(split.arrangedSubviews[0].frame.width, 700)
    }
}
