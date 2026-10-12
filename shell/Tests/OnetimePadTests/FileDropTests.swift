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

    func testAWebLinkIsNotAFileAndIsNotOpenedAsOne() {
        // A link dragged out of a browser arrives as a URL too. Its path
        // component is not a path on this disk, even when it looks like
        // one, and forwarding it would open whatever that path names.
        let link = URL(string: "https://example.com/private/etc/hosts")!
        let file = URL(fileURLWithPath: "/tmp/notes.txt")
        var opened: [URL] = []

        XCTAssertFalse(BackdropRootView.forwardDroppedURLs([link]) { opened.append($0) })
        XCTAssertTrue(opened.isEmpty)

        XCTAssertTrue(BackdropRootView.forwardDroppedURLs([link, file]) { opened.append($0) })
        XCTAssertEqual(opened, [file], "the file in a mixed drop still opens; the link does not")
    }

    func testAnEmptyDropIsNotHandled() {
        var opened: [URL] = []

        XCTAssertFalse(BackdropRootView.forwardDroppedURLs([]) { opened.append($0) })
        XCTAssertTrue(opened.isEmpty)
    }
}
