import XCTest

@testable import OnetimePad

final class LanguageDetectionMenuTests: XCTestCase {
    func testEligibleEditorTargetTakesPrecedenceOverWholeFile() {
        XCTAssertEqual(
            ManualLanguageChoiceTarget.resolve(editorCanChoose: true, selectedFile: 42),
            .editor
        )
    }

    func testActiveFileIsManualTargetWhenEditorDetectionHasNoTarget() {
        XCTAssertEqual(
            ManualLanguageChoiceTarget.resolve(editorCanChoose: false, selectedFile: 42),
            .file(42)
        )
    }

    func testNoEditorOrFileLeavesManualPickerDisabled() {
        XCTAssertNil(
            ManualLanguageChoiceTarget.resolve(editorCanChoose: false, selectedFile: nil)
        )
    }
}
