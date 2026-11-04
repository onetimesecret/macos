import AppKit
import SwiftUI
import XCTest

@testable import CompanionKit

@MainActor
final class TimelineSplitViewTests: XCTestCase {
    private struct Mounted {
        let window: NSWindow
        let host: NSHostingView<AnyView>
        let root: (Bool) -> AnyView
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
    }

    private func defaults() throws -> UserDefaults {
        let suite = "timeline-split-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func timelineModel(defaults: UserDefaults) -> PageModel {
        let model = isolatedModel(defaults: defaults)
        model.newPage()
        model.showsTimeUnits = true
        return model
    }

    private func mount(_ model: PageModel, width: CGFloat = 640) -> Mounted {
        let root = { (showsTimeline: Bool) -> AnyView in
            AnyView(TimelineSplitView(
                showsTimeline: showsTimeline,
                railWidth: model.timelineWidth, onRailResize: model.recordTimelineWidth
            ) {
                TimeRailView(model: model, readOnly: false)
            } content: {
                PageContentView(model: model, emptyHint: "", showsExpandControl: false)
            }.environment(\.presentationSurface, model.owner))
        }
        let host = NSHostingView(rootView: root(true))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        layout(host)
        return Mounted(window: window, host: host, root: root)
    }

    private func layout(_ host: NSView) {
        for _ in 0..<2 {
            host.layoutSubtreeIfNeeded()
            drainMainQueue()
        }
        host.layoutSubtreeIfNeeded()
    }

    private func splitView(in host: NSView) throws -> NSSplitView {
        try XCTUnwrap(descendants(NSSplitView.self, in: host).first)
    }

    /// A person's drag: the divider moves, then AppKit posts the resize with the keys
    /// `didResizeSubviewsNotification` documents for a drag. A bare `setPosition` is a program's move.
    private func drag(_ split: NSSplitView, to position: CGFloat, in host: NSView) {
        split.setPosition(position, ofDividerAt: 0)
        NotificationCenter.default.post(
            name: NSSplitView.didResizeSubviewsNotification, object: split,
            userInfo: ["NSSplitViewDividerIndex": NSNumber(value: 0), "NSSplitViewUserResizeKey": NSNumber(value: 1)])
        layout(host)
    }

    private func resize(_ mounted: Mounted, width: CGFloat) {
        mounted.window.setContentSize(NSSize(width: width, height: 400))
        layout(mounted.host)
    }

    func testNativeDividerResizesTheRailAndPageAndSurvivesUpdates() throws {
        let model = timelineModel(defaults: try defaults())
        let mounted = mount(model)
        let host = mounted.host
        defer { mounted.window.close() }

        let split = try splitView(in: host)
        XCTAssertTrue(split.isVertical)
        XCTAssertEqual(split.arrangedSubviews.count, 2)
        XCTAssertEqual(split.arrangedSubviews[0].frame.width, TimeRailView.width, accuracy: 2)
        let editor = try XCTUnwrap(descendants(InkTextView.self, in: host).first)
        let pageWidth = split.arrangedSubviews[1].frame.width

        drag(split, to: 180, in: host)
        XCTAssertEqual(split.arrangedSubviews[0].frame.width, 180, accuracy: 2)
        XCTAssertEqual(pageWidth - split.arrangedSubviews[1].frame.width, 70, accuracy: 2)
        XCTAssertTrue(descendants(InkTextView.self, in: host).first === editor)
        XCTAssertEqual(model.timelineWidth, 180, accuracy: 2, "the divider move was not recorded")

        model.pads.isEnabled = true
        host.rootView = mounted.root(true)
        layout(host)
        XCTAssertEqual(split.arrangedSubviews[0].frame.width, 180, accuracy: 2)

        drag(split, to: 0, in: host)
        XCTAssertEqual(split.arrangedSubviews[0].frame.width, TimeRailView.width, accuracy: 2)

        drag(split, to: 500, in: host)
        XCTAssertEqual(split.arrangedSubviews[0].frame.width, TimeRailView.maxWidth, accuracy: 2)
        XCTAssertTrue(descendants(InkTextView.self, in: host).first === editor)
        XCTAssertEqual(model.timelineWidth, TimeRailView.maxWidth, accuracy: 2)

        split.setPosition(150, ofDividerAt: 0)
        layout(host)
        XCTAssertEqual(model.timelineWidth, TimeRailView.maxWidth, accuracy: 2, "a program's move was recorded")
        XCTAssertEqual(
            split.arrangedSubviews[0].frame.width, TimeRailView.maxWidth, accuracy: 2,
            "the divider did not return to the person's width")

        resize(mounted, width: 720)
        XCTAssertEqual(split.arrangedSubviews[0].frame.width, TimeRailView.maxWidth, accuracy: 2)

        host.rootView = mounted.root(false)
        layout(host)
        XCTAssertEqual(split.arrangedSubviews.count, 1)
        XCTAssertGreaterThan(split.arrangedSubviews[0].frame.width, 700)
        XCTAssertTrue(
            descendants(InkTextView.self, in: host).first === editor, "hiding the timeline remounted the editor")
    }

    /// At the floor both windows share, the rail yields and the page keeps its minimum;
    /// the yield is not recorded, and widening the window gives the rail its width back.
    func testTheRailYieldsToThePageAtTheWindowFloor() throws {
        let model = timelineModel(defaults: try defaults())
        model.recordTimelineWidth(TimeRailView.maxWidth)
        let mounted = mount(model)
        defer { mounted.window.close() }
        let split = try splitView(in: mounted.host)
        XCTAssertEqual(split.arrangedSubviews[0].frame.width, TimeRailView.maxWidth, accuracy: 2)

        let floor: CGFloat = 360
        resize(mounted, width: floor)
        XCTAssertEqual(
            split.arrangedSubviews[1].frame.width, TimelineSplit.pageMinWidth, accuracy: 2,
            "the page gave up its minimum")
        XCTAssertEqual(
            split.arrangedSubviews[0].frame.width, TimelineSplit.railCeiling(splitWidth: floor), accuracy: 2)
        XCTAssertEqual(model.timelineWidth, TimeRailView.maxWidth, accuracy: 0.5, "a window resize was recorded")

        resize(mounted, width: 640)
        XCTAssertEqual(
            split.arrangedSubviews[0].frame.width, TimeRailView.maxWidth, accuracy: 2,
            "the rail stayed squeezed after the window widened")
        XCTAssertNotNil(descendants(InkTextView.self, in: mounted.host).first)
    }

    /// A window that opens too narrow for the stored width shows the ceiling and keeps the stored width.
    func testANarrowMountKeepsTheStoredWidth() throws {
        let model = timelineModel(defaults: try defaults())
        model.recordTimelineWidth(TimeRailView.maxWidth)
        let floor: CGFloat = 360
        let mounted = mount(model, width: floor)
        defer { mounted.window.close() }
        let split = try splitView(in: mounted.host)
        XCTAssertEqual(
            split.arrangedSubviews[0].frame.width, TimelineSplit.railCeiling(splitWidth: floor), accuracy: 2)
        XCTAssertEqual(model.timelineWidth, TimeRailView.maxWidth, accuracy: 0.5, "the clamped start was recorded")
    }

    /// A drag past the ceiling at the floor stops where the page keeps its minimum.
    func testADragAtTheFloorLeavesThePageItsMinimum() throws {
        let model = timelineModel(defaults: try defaults())
        let floor: CGFloat = 360
        let mounted = mount(model, width: floor)
        defer { mounted.window.close() }
        let split = try splitView(in: mounted.host)
        drag(split, to: TimeRailView.maxWidth, in: mounted.host)
        XCTAssertEqual(
            split.arrangedSubviews[1].frame.width, TimelineSplit.pageMinWidth, accuracy: 2,
            "the drag took the page under its minimum")
        XCTAssertEqual(
            model.timelineWidth, TimelineSplit.railCeiling(splitWidth: floor), accuracy: 2,
            "the person's drag was not recorded")
    }

    /// The dragged width returns when the rail comes back and when the app relaunches.
    func testTheDraggedWidthPersistsAcrossHidingAndRelaunch() throws {
        let store = try defaults()
        let model = timelineModel(defaults: store)
        let mounted = mount(model)
        defer { mounted.window.close() }
        let split = try splitView(in: mounted.host)
        drag(split, to: 180, in: mounted.host)
        XCTAssertEqual(model.timelineWidth, 180, accuracy: 2)

        mounted.host.rootView = mounted.root(false)
        layout(mounted.host)
        XCTAssertEqual(try splitView(in: mounted.host).arrangedSubviews.count, 1)
        mounted.host.rootView = mounted.root(true)
        layout(mounted.host)
        let returned = try splitView(in: mounted.host)
        XCTAssertEqual(returned.arrangedSubviews.count, 2)
        XCTAssertEqual(returned.arrangedSubviews[0].frame.width, 180, accuracy: 2, "the rail came back at its start width")

        let relaunched = timelineModel(defaults: store)
        XCTAssertEqual(relaunched.timelineWidth, 180, accuracy: 2)
        let remounted = mount(relaunched)
        defer { remounted.window.close() }
        XCTAssertEqual(try splitView(in: remounted.host).arrangedSubviews[0].frame.width, 180, accuracy: 2)
    }

    func testAStoredWidthIsReadInsideTheRailsRange() throws {
        let store = try defaults()
        store.set(900.0, forKey: "timelineWidth")
        XCTAssertEqual(timelineModel(defaults: store).timelineWidth, TimeRailView.maxWidth)
        store.set(12.0, forKey: "timelineWidth")
        XCTAssertEqual(timelineModel(defaults: store).timelineWidth, TimeRailView.width)
        store.set("wide", forKey: "timelineWidth")
        XCTAssertEqual(timelineModel(defaults: store).timelineWidth, TimeRailView.width)
        store.removeObject(forKey: "timelineWidth")
        XCTAssertEqual(timelineModel(defaults: store).timelineWidth, TimeRailView.width)
    }

    func testTheCeilingLeavesThePageItsMinimum() {
        XCTAssertEqual(TimelineSplit.railCeiling(splitWidth: 1_000), TimeRailView.maxWidth)
        XCTAssertEqual(
            TimelineSplit.railCeiling(splitWidth: 360),
            360 - TimelineSplit.pageMinWidth - TimelineSplit.dividerWidth)
        XCTAssertEqual(TimelineSplit.railCeiling(splitWidth: 200), TimeRailView.width, "the rail never goes under its start")
        XCTAssertEqual(TimelineSplit.railCeiling(splitWidth: 0), TimeRailView.maxWidth, "an unmeasured split binds nothing")
    }
}
