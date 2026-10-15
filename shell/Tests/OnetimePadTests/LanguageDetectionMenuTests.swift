import CompanionKit
import XCTest

@testable import OnetimePad

final class LanguageDetectionMenuTests: XCTestCase {
    func testEligibleEditorTargetTakesPrecedenceOverWholeFile() {
        XCTAssertEqual(
            ManualLanguageChoiceTarget.resolve(
                editorCanChoose: true,
                editorSelectionIsEmpty: false,
                selectedFile: 42
            ),
            .editor
        )
    }

    func testActiveFileIsManualTargetWhenEditorSelectionIsEmpty() {
        XCTAssertEqual(
            ManualLanguageChoiceTarget.resolve(
                editorCanChoose: false,
                editorSelectionIsEmpty: true,
                selectedFile: 42
            ),
            .file(42)
        )
    }

    func testIneligibleNonemptySelectionLeavesManualPickerDisabled() {
        XCTAssertNil(
            ManualLanguageChoiceTarget.resolve(
                editorCanChoose: false,
                editorSelectionIsEmpty: false,
                selectedFile: 42
            )
        )
    }

    /// An editor's choice goes down the responder chain with its language,
    /// never to the page directly (Law 0007, keys row); a file's goes to its mode.
    @MainActor
    func testAChoiceGoesDownTheChainOrToTheFile() throws {
        var sent: [(Selector, String?)] = []
        var chosen: [(FileRenderMode, UInt64)] = []
        ManualLanguageChoiceTarget.editor.choose(
            "rust", send: { sent.append(($0, ($1 as? CodeLanguageChoice)?.language)) },
            selectFileMode: { chosen.append(($0, $1)) })
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.0, #selector(LanguageDetectionResponder.chooseCodeLanguage(_:)))
        XCTAssertEqual(sent.first?.1, "rust")
        XCTAssertTrue(chosen.isEmpty)

        ManualLanguageChoiceTarget.file(42).choose(
            "rust", send: { sent.append(($0, ($1 as? CodeLanguageChoice)?.language)) },
            selectFileMode: { chosen.append(($0, $1)) })
        XCTAssertEqual(sent.count, 1, "a file's choice went down the chain")
        XCTAssertEqual(chosen.first?.0, .source("rust"))
        XCTAssertEqual(chosen.first?.1, 42)
    }

    func testNoEditorOrFileLeavesManualPickerDisabled() {
        XCTAssertNil(
            ManualLanguageChoiceTarget.resolve(
                editorCanChoose: false,
                editorSelectionIsEmpty: nil,
                selectedFile: nil
            )
        )
    }
}
