import Foundation
import XCTest

@testable import CompanionKit

final class CompanionClientLanguageDetectionTests: XCTestCase {
    private let python = Data("""
        def total(values):
            return sum(value for value in values if value > 0)

        print(total([1, -2, 3]))
        """.utf8)

    func testEmptyInputUsesTheStatelessWrapperAndAbstains() {
        XCTAssertNil(CompanionClient.detectSourceLanguage(in: Data()))
    }

    func testSuccessfulResultIsCopiedFromTheOwnedCString() {
        XCTAssertEqual(CompanionClient.detectSourceLanguage(in: python), "python")
    }

    func testIneligibleByteBuffersAbstain() {
        XCTAssertNil(CompanionClient.detectSourceLanguage(
            in: Data("fn main() {\0 println!(\"no\"); }".utf8)
        ))
        XCTAssertNil(CompanionClient.detectSourceLanguage(in: Data(repeating: 0xff, count: 20)))
        XCTAssertNil(CompanionClient.detectSourceLanguage(
            in: Data(repeating: 0x78, count: 4 * 1024 * 1024 + 1)
        ))
    }

    func testStatelessWrapperSupportsConcurrentCalls() {
        let input = python
        let results = LockedResults()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            results.append(CompanionClient.detectSourceLanguage(in: input))
        }
        XCTAssertEqual(results.values, Array(repeating: "python", count: 8))
    }
}

private final class LockedResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String?] = []

    var values: [String?] {
        lock.withLock { storage }
    }

    func append(_ value: String?) {
        lock.withLock { storage.append(value) }
    }
}
