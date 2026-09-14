import XCTest

@testable import OnetimePad

@MainActor
final class FileDropTests: XCTestCase {
    func testEveryDroppedURLIsForwardedRegardlessOfSuffix() {
        let urls = [
            URL(fileURLWithPath: "/tmp/notes.unknown"),
            URL(fileURLWithPath: "/tmp/Makefile"),
            URL(fileURLWithPath: "/tmp/shot.png"),
            URL(fileURLWithPath: "/tmp/folder", isDirectory: true),
        ]
        var opened: [URL] = []

        XCTAssertTrue(BackdropRootView.forwardDroppedURLs(urls) { opened.append($0) })
        XCTAssertEqual(opened, urls)
    }

    func testAnEmptyDropIsNotHandled() {
        var opened: [URL] = []

        XCTAssertFalse(BackdropRootView.forwardDroppedURLs([]) { opened.append($0) })
        XCTAssertTrue(opened.isEmpty)
    }
}
