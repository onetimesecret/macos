import AppKit
import SwiftUI
import XCTest

@testable import CompanionKit

@MainActor
final class MarkdownDialectSettingTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "companion-markdown-dialect-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testMissingOrUnknownValueUsesGFMWithoutRewritingDefaults() throws {
        let defaults = try makeDefaults()
        XCTAssertEqual(isolatedModel(defaults: defaults).markdownDialect, .gfm)
        XCTAssertNil(defaults.object(forKey: "markdownDialect"))
        for value in ["future-dialect", "", "CommonMark"] {
            defaults.set(value, forKey: "markdownDialect")
            XCTAssertEqual(isolatedModel(defaults: defaults).markdownDialect, .gfm)
            XCTAssertEqual(defaults.string(forKey: "markdownDialect"), value)
        }
    }

    func testEachDialectPersistsAndIsReadByTheNextModel() throws {
        let defaults = try makeDefaults()
        let first = isolatedModel(defaults: defaults)
        for dialect in [PreviewDialect.commonMark, .gfm] {
            first.markdownDialect = dialect
            XCTAssertEqual(defaults.string(forKey: "markdownDialect"), dialect.rawValue)
            XCTAssertEqual(isolatedModel(defaults: defaults).markdownDialect, dialect)
        }
    }

    func testDistinctChangesInvalidateOnceWithoutMarkingPageContentDirty() throws {
        let model = isolatedModel(defaults: try makeDefaults())
        model.loadStateIfNeeded()
        let marks = model.dirtyMarks
        let page = try XCTUnwrap(model.selectedPageID)
        let cached = model.quietRendering(for: page)
        let posts = PostCount()
        let observer = NotificationCenter.default.addObserver(
            forName: PageModel.quietRenderingsDidInvalidateNotification, object: model, queue: nil
        ) { _ in MainActor.assumeIsolated { posts.count += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }

        model.markdownDialect = .commonMark
        XCTAssertEqual(posts.count, 1)
        let changed = model.quietRendering(for: page)
        XCTAssertFalse(changed === cached)
        model.markdownDialect = .commonMark
        XCTAssertEqual(posts.count, 1)
        XCTAssertTrue(model.quietRendering(for: page) === changed)
        model.markdownDialect = .gfm
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(model.dirtyMarks, marks)
    }

    func testDialectIsIndependentOfPreviewScopeAndPageToggle() throws {
        let model = isolatedModel(defaults: try makeDefaults())
        model.loadStateIfNeeded()
        let page = try XCTUnwrap(model.selectedPageID)
        for scope in PreviewRenderingScope.allCases {
            model.previewRendering = scope
            for enabled in [true, false] {
                model.toggleMarkdownPreview(for: page)
                for dialect in PreviewDialect.allCases {
                    model.markdownDialect = dialect
                    XCTAssertEqual(model.previewRendering, scope)
                    XCTAssertEqual(model.markdownPreviewEnabled(for: page), enabled)
                }
            }
        }
    }

    func testSettingsLayoutWithBothDialectSelections() throws {
        let model = isolatedModel(defaults: try makeDefaults())
        let host = NSHostingView(rootView: CodeSettingsView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 390)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for dialect in PreviewDialect.allCases {
            model.markdownDialect = dialect
            drainMainQueue()
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.frame.size, NSSize(width: 480, height: 390))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let directory = ProcessInfo.processInfo.environment["PREVIEW_QA_ARTIFACTS"] {
                let output = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent("dialect-settings-\(dialect.rawValue).png"))
            }
        }
    }

    @MainActor
    private final class PostCount {
        var count = 0
    }
}
