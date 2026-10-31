import Foundation
import XCTest

@testable import CompanionKit

final class ContinuousDocumentProjectionTests: XCTestCase {
    private typealias Projection = ContinuousDocumentProjection

    private func projection(_ strings: [String], joins: [Int: String] = [:]) -> Projection {
        Projection(pages: strings.enumerated().map { index, text in
            Projection.Page(id: UInt64(index + 1), uuid: "page-\(index + 1)", text: text,
                joinedNextUUID: joins[index + 1])
        })
    }

    func testDefaultSeparatorsAndMatchingJoinIdentity() {
        let source = projection(["alpha", "bravo", "charlie"], joins: [1: "page-2", 2: "other-page"])
        XCTAssertEqual(source.text, "alphabravo\ncharlie")
        XCTAssertEqual(source.segments.map(\.bodyRange), [
            NSRange(location: 0, length: 5), NSRange(location: 5, length: 5),
            NSRange(location: 11, length: 7)
        ])
        XCTAssertNil(source.segments[0].separatorRange)
        XCTAssertEqual(source.segments[1].separatorRange, NSRange(location: 10, length: 1))
    }

    func testCrossPageReplacementUsesUpdatedOffsetsAndRetainsEmptyPages() throws {
        let source = projection(["alpha", "bravo", "charlie"])
        let plan = try source.plan([.del(at: 2, len: 12), .ins(at: 2, text: "NEW")])
        XCTAssertEqual(plan.projection.text, "alNEWarlie")
        XCTAssertEqual(plan.projection.pages.map(\.text), ["alNEW", "", "arlie"])
        XCTAssertEqual(plan.projection.pages.map(\.id), [1, 2, 3])
        XCTAssertEqual(plan.edits, [
            .init(pageID: 1, pageUUID: "page-1", ops: [.del(at: 2, len: 3), .ins(at: 2, text: "NEW")], join: .set("page-2")),
            .init(pageID: 2, pageUUID: "page-2", ops: [.del(at: 0, len: 5)], join: .set("page-3")),
            .init(pageID: 3, pageUUID: "page-3", ops: [.del(at: 0, len: 2)], join: .unchanged)
        ])
    }

    func testDeletingOnlySeparatorChangesJoinWithoutBodyEdits() throws {
        let plan = try projection(["first", "second"]).plan([.del(at: 5, len: 1)])
        XCTAssertEqual(plan.projection.text, "firstsecond")
        XCTAssertEqual(plan.projection.pages.map(\.text), ["first", "second"])
        XCTAssertEqual(plan.edits, [
            .init(pageID: 1, pageUUID: "page-1", ops: [], join: .set("page-2"))
        ])
        XCTAssertEqual(Projection(pages: plan.projection.pages).text, "firstsecond")
    }

    func testInsertionAtEachSideOfSeparatorAndAtJoinedEdge() throws {
        let source = projection(["a", "b"])
        let before = try source.plan([.ins(at: 1, text: "x")])
        XCTAssertEqual(before.projection.pages.map(\.text), ["ax", "b"])
        let after = try source.plan([.ins(at: 2, text: "x")])
        XCTAssertEqual(after.projection.pages.map(\.text), ["a", "xb"])
        let joined = try source.plan([.del(at: 1, len: 1), .ins(at: 1, text: "x")])
        XCTAssertEqual(joined.projection.pages.map(\.text), ["ax", "b"])
        let later = try source.plan([.del(at: 1, len: 1)]).projection.plan([.ins(at: 1, text: "x")])
        XCTAssertEqual(later.projection.pages.map(\.text), ["a", "xb"])
    }

    func testMultipleEmptyPagesRemainDistinctAndLastJoinedPageReceivesInsertion() throws {
        let source = projection(["", "", ""])
        XCTAssertEqual(source.text, "\n\n")
        XCTAssertEqual(source.page(at: 0)?.page.id, 1)
        XCTAssertEqual(source.page(at: 1)?.page.id, 2)
        XCTAssertEqual(source.page(at: 2)?.page.id, 3)
        let plan = try source.plan([.del(at: 0, len: 2)]).projection.plan([.ins(at: 0, text: "ink")])
        XCTAssertEqual(plan.projection.pages.map(\.text), ["", "", "ink"])
        XCTAssertEqual(plan.projection.text, "ink")
        XCTAssertEqual(plan.edits.map(\.pageID), [3])
    }

    func testUnicodeRangeAndChipOffsetsAreUTF16() throws {
        let source = projection(["a😀", "🦊z"])
        let plan = try source.plan([.del(at: 1, len: 5), .chip(at: 1, id: 42)])
        XCTAssertEqual(plan.projection.text, "a\u{fffc}z")
        XCTAssertEqual(plan.edits[0].ops, [.del(at: 1, len: 2), .chip(at: 1, id: 42)])
        XCTAssertEqual(plan.edits[1].ops, [.del(at: 0, len: 2)])
    }

    func testSequentialDeletesAndWholeDocumentReplacement() throws {
        let source = projection(["ab", "cd", "ef"])
        let joined = try source.plan([.del(at: 2, len: 1), .del(at: 4, len: 1)])
        XCTAssertEqual(joined.projection.text, "abcdef")
        XCTAssertEqual(joined.edits.map(\.join), [.set("page-2"), .set("page-3")])
        let replaced = try source.plan([.del(at: 0, len: source.length), .ins(at: 0, text: "new")])
        XCTAssertEqual(replaced.projection.pages.map(\.text), ["new", "", ""])
        XCTAssertEqual(replaced.projection.text, "new")
    }

    func testSurrogateSplitsAndInvalidRangesAreRejected() {
        let source = projection(["😀", "z"])
        for op in [DocumentEditOp.ins(at: 1, text: "x"), .del(at: 0, len: 1), .del(at: 1, len: 1)] {
            XCTAssertThrowsError(try source.plan([op])) { error in
                XCTAssertEqual(error as? Projection.PlanningError, .splitUnicodeScalar)
            }
        }
        for op in [DocumentEditOp.del(at: -1, len: 1), .del(at: 0, len: -1),
                   .del(at: 2, len: Int.max), .ins(at: Int.max, text: "x")] {
            XCTAssertThrowsError(try source.plan([op])) { error in
                XCTAssertEqual(error as? Projection.PlanningError, .invalidRange)
            }
        }
        XCTAssertEqual(source.text, "😀\nz")
    }

    func testJoinedAndSeparatedUnicodeRangesMatchNativeTextReplacement() throws {
        for joins in [[Int: String](), [1: "page-2", 2: "page-3"]] {
            let source = projection(["a😀", "", "🦊e\u{301}", "z"], joins: joins)
            let original = source.text as NSString
            let units = Array(source.text.utf16)
            let validOffsets = (0...units.count).filter { offset in
                offset == 0 || offset == units.count ||
                    !((0xD800...0xDBFF).contains(units[offset - 1]) && (0xDC00...0xDFFF).contains(units[offset]))
            }
            for start in validOffsets {
                for end in validOffsets where end >= start {
                    let range = NSRange(location: start, length: end - start)
                    let result = try source.plan([.del(at: start, len: range.length), .ins(at: start, text: "🐈")])
                    XCTAssertEqual(result.projection.text, original.replacingCharacters(in: range, with: "🐈"))
                    XCTAssertEqual(result.projection.length, result.projection.text.utf16.count)
                }
            }
        }
    }

    func testSurrogateSplitsOnLaterJoinedPageAreRejected() {
        let source = projection(["a😀", "", "🦊z"], joins: [1: "page-2", 2: "page-3"])
        for op in [DocumentEditOp.ins(at: 4, text: "x"), .del(at: 3, len: 1), .del(at: 1, len: 3)] {
            XCTAssertThrowsError(try source.plan([op])) { error in
                XCTAssertEqual(error as? Projection.PlanningError, .splitUnicodeScalar)
            }
        }
    }

    func testEmptyProjectionRefusesNonemptyInsertionAndDuplicatePagesAreRejected() throws {
        XCTAssertEqual(try projection([]).plan([]).edits, [])
        XCTAssertThrowsError(try projection([]).plan([.ins(at: 0, text: "x")])) { error in
            XCTAssertEqual(error as? Projection.PlanningError, .noPage)
        }
        let page = Projection.Page(id: 1, uuid: "page-1", text: "a")
        XCTAssertThrowsError(try Projection(pages: [page, page]).plan([])) { error in
            XCTAssertEqual(error as? Projection.PlanningError, .invalidPages)
        }
    }
}
