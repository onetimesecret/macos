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
