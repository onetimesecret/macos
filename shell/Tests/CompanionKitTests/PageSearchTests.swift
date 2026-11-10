import AppKit
import XCTest

@testable import CompanionKit

final class PageSearchTests: XCTestCase {
    private func source(_ id: UInt64, _ text: String, stamp: UInt64? = nil) -> PageSearchSource {
        PageSearchSource(id: id, title: "source \(id)", stamp: stamp, text: text)
    }

    func testEveryWordMustBeOnTheLineInAnyOrder() {
        let rows = PageSearch.rows(for: "alpha  beta", in: [source(1, "alpha only\nbeta then alpha\nneither")])
        XCTAssertEqual(rows.map(\.line), [1])
        XCTAssertEqual(rows.first?.excerpt, "beta then alpha")
        XCTAssertEqual(rows.first?.id, 1)
        XCTAssertEqual(rows.first?.title, "source 1")
    }

    func testMatchingIgnoresCaseAndDiacritics() {
        let rows = PageSearch.rows(for: "cafe RESUME", in: [source(1, "Café résumé")])
        XCTAssertEqual(rows.map(\.excerpt), ["Café résumé"])
    }

    func testWordsOnDifferentLinesDoNotMatch() {
        XCTAssertTrue(PageSearch.rows(for: "alpha beta", in: [source(1, "alpha\nbeta")]).isEmpty)
        XCTAssertTrue(PageSearch.rows(for: "alpha beta", in: [source(1, "alpha\r\nbeta")]).isEmpty)
    }

    func testRowsStopAtTheCap() {
        let text = (0..<60).map { "needle \($0)" }.joined(separator: "\n")
        let rows = PageSearch.rows(for: "needle", in: [source(1, text), source(2, text)])
        XCTAssertEqual(rows.count, PageSearch.rowCap)
        XCTAssertEqual(rows.map(\.line), Array(0..<50))
        XCTAssertEqual(PageSearch.rows(for: "needle", in: [source(1, text)], cap: 3).map(\.line), [0, 1, 2])
    }

    func testRowsRunNewestStampFirstThenInLineOrder() {
        let text = "needle a\nother\nneedle b"
        let rows = PageSearch.rows(for: "needle", in: [
            source(1, text, stamp: 100), source(2, text), source(3, text, stamp: 300), source(4, text, stamp: 100)
        ])
        XCTAssertEqual(rows.map(\.id), [3, 3, 1, 1, 4, 4, 2, 2])
        XCTAssertEqual(rows.map(\.line), [0, 2, 0, 2, 0, 2, 0, 2])
        XCTAssertEqual(rows.first?.stamp, 300)
        XCTAssertNil(rows.last?.stamp)
    }

    func testALongLineIsCutAroundItsFirstMatch() {
        let a = String(repeating: "a", count: 150)
        let b = String(repeating: "b", count: 100)
        let start = PageSearch.rows(for: "needle", in: [source(1, "needle " + a)])
        XCTAssertEqual(start.map(\.excerpt), ["needle " + String(repeating: "a", count: 73) + "…"])
        let middle = PageSearch.rows(for: "needle", in: [source(1, String(a.prefix(100)) + " needle " + b)])
        XCTAssertEqual(middle.map(\.excerpt), [
            "…" + String(repeating: "a", count: 19) + " needle " + String(repeating: "b", count: 53) + "…"
        ])
        let end = PageSearch.rows(for: "needle", in: [source(1, a + " needle")])
        XCTAssertEqual(end.map(\.excerpt), ["…" + String(repeating: "a", count: 73) + " needle"])
    }

    func testAShortLineIsShownWithoutItsIndentation() {
        XCTAssertEqual(PageSearch.rows(for: "needle", in: [source(1, "\t  indented needle  ")]).map(\.excerpt),
            ["indented needle"])
    }

    func testAnEmptyQueryFindsNothing() {
        XCTAssertTrue(PageSearch.rows(for: "", in: [source(1, "anything")]).isEmpty)
        XCTAssertTrue(PageSearch.rows(for: " \t ", in: [source(1, "anything")]).isEmpty)
    }

    func testALinesOffsetCountsUTF16UnitsAsTheRowsCountLines() {
        let text = "one\ntwo 😀\r\nthree"
        XCTAssertEqual(PageSearch.rows(for: "three", in: [source(1, text)]).map(\.line), [2])
        XCTAssertEqual(PageSearch.utf16Offset(ofLine: 0, in: text), 0)
        XCTAssertEqual(PageSearch.utf16Offset(ofLine: 1, in: text), 4)
        XCTAssertEqual(PageSearch.utf16Offset(ofLine: 2, in: text), 12)
        XCTAssertNil(PageSearch.utf16Offset(ofLine: 3, in: text))
        XCTAssertNil(PageSearch.utf16Offset(ofLine: -1, in: text))
    }
}

@MainActor
final class PageSearchModelTests: XCTestCase {
    private func makeModel() throws -> (model: PageModel, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "page-search-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let model = PageModel(formFactor: .panel, defaults: defaults,
            seams: .init(stateDirectory: directory,
                client: .ephemeral(tag: suite), saveDebounce: 3_600,
                saveRetryDebounce: 3_600))
        model.loadStateIfNeeded()
        return (model, directory)
    }

    private func seed(_ text: String, in model: PageModel) throws -> (tab: UInt64, page: UInt64) {
        let tab = try XCTUnwrap(model.selectedTab)
        let page = try XCTUnwrap(tab.pageID)
        model.applyOps(sheet: page,
            opsJSON: try XCTUnwrap(DocumentEditOp.wireJSON([.ins(at: 0, text: text)])))
        return (tab.id, page)
    }

    func testAQueryEqualToASealedObjectsPlaintextFindsNothing() throws {
        let (model, _) = try makeModel()
        let (tab, page) = try seed("visible ink\nbeside after", in: model)
        _ = try XCTUnwrap(model.coreClient.sealText(sheet: page, "tangerine", at: 19, length: 0))
        model.refresh()

        let sources = model.pageSearchSources()

        XCTAssertEqual(sources.map(\.id), [tab])
        XCTAssertTrue(PageSearch.rows(for: "tangerine", in: sources).isEmpty)
        XCTAssertEqual(PageSearch.rows(for: "visible", in: sources).map(\.line), [0])
        let placeholder = try XCTUnwrap(PageSearch.rows(for: "sealed content", in: sources).first)
        XCTAssertEqual(placeholder.line, 1)
        XCTAssertTrue(placeholder.excerpt.hasPrefix("beside [sealed content · "))
        XCTAssertTrue(placeholder.excerpt.hasSuffix("]after"))
    }

    func testOpeningARowReopensAClosedPageWithTheCaretAtItsLine() throws {
        let (model, _) = try makeModel()
        let (tab, page) = try seed("first line\nsecond needle\nthird", in: model)
        model.closeCurrent()
        XCTAssertEqual(model.closedTabs.map(\.id), [tab])

        let row = try XCTUnwrap(PageSearch.rows(for: "needle", in: model.pageSearchSources()).first)
        XCTAssertEqual(row.id, tab)
        XCTAssertEqual(row.line, 1)
        XCTAssertTrue(model.openSearchRow(row))

        XCTAssertTrue(model.closedTabs.isEmpty)
        XCTAssertEqual(model.selection, tab)
        XCTAssertEqual(model.selectedPageID, page)
        XCTAssertEqual(model.viewStates.carets[page], NSRange(location: 11, length: 0))
        XCTAssertEqual(model.viewStates.scrolls[page], ScrollAnchor(characterIndex: 11))
        XCTAssertFalse(model.openSearchRow(
            PageSearchRow(id: tab + 1_000, title: "", stamp: nil, line: 0, excerpt: "")))
    }

    func testAnOpenFileIsSearchedAndItsRowShowsItAtTheLine() throws {
        let (model, directory) = try makeModel()
        let tab = try XCTUnwrap(model.selectedTab)
        let file = directory.appendingPathComponent("notes.txt")
        try "top\nfile needle".write(to: file, atomically: true, encoding: .utf8)
        model.openFile(at: file)
        let opened = try XCTUnwrap(model.activeFile)
        model.select(tab.id)
        XCTAssertNil(model.selectedFile)

        let row = try XCTUnwrap(PageSearch.rows(for: "file needle", in: model.pageSearchSources()).first)
        XCTAssertEqual(row.id, opened.id)
        XCTAssertEqual(row.title, "notes.txt")
        XCTAssertEqual(row.line, 1)
        XCTAssertTrue(model.openSearchRow(row))

        XCTAssertEqual(model.selectedFile, opened.id)
        XCTAssertEqual(model.viewStates.carets[opened.id], NSRange(location: 4, length: 0))
    }
}
