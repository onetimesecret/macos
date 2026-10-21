import CompanionCore
import Foundation
import XCTest

@testable import CompanionKit

final class ContentJSONDecodingTests: XCTestCase {
    private struct Payload: Codable, Equatable {
        let ink: String
    }

    private func allocate(_ bytes: [UInt8]) -> UnsafeMutablePointer<CChar> {
        let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count + 1)
        for (index, byte) in bytes.enumerated() {
            pointer[index] = CChar(bitPattern: byte)
        }
        pointer[bytes.count] = 0
        return pointer
    }

    func testNullDoesNotDecodeOrRelease() {
        let result = decodeOwnedJSON(Payload.self, from: nil, release: { _ in
            XCTFail("nil has no allocation to release")
        }, decode: { _, _ in
            XCTFail("nil has no JSON to decode")
            return Payload(ink: "")
        })
        XCTAssertNil(result)
    }

    func testEscapedContentDecodesBeforeExactlyOneRelease() throws {
        let expected = Payload(ink: "quote \" slash \\ newline\nNUL\0 café 🦀")
        let json = try JSONEncoder().encode(expected)
        let pointer = allocate(Array(json))
        var releaseCount = 0
        let result = decodeOwnedJSON(Payload.self, from: pointer, release: { released in
            XCTAssertEqual(released, pointer)
            XCTAssertEqual(strlen(released), json.count)
            releaseCount += 1
            released.deallocate()
        }, decode: { type, data in
            XCTAssertEqual(releaseCount, 0)
            XCTAssertEqual(data, json)
            return try JSONDecoder().decode(type, from: data)
        })
        XCTAssertEqual(result, expected)
        XCTAssertEqual(releaseCount, 1)
    }

    func testMalformedAndMismatchedContentReleaseExactlyOnce() {
        for json in ["", "{\"ink\":", "{\"ink\":42}", "null", "[]"] {
            let pointer = allocate(Array(json.utf8))
            var releaseCount = 0
            let result = decodeOwnedJSON(Payload.self, from: pointer, release: { released in
                releaseCount += 1
                released.deallocate()
            })
            XCTAssertNil(result, json)
            XCTAssertEqual(releaseCount, 1, json)
        }
    }

    func testInvalidUTF8ReleasesExactlyOnce() {
        let pointer = allocate([0x7b, 0x22, 0x69, 0x6e, 0x6b, 0x22, 0x3a, 0x22, 0xff, 0x22, 0x7d])
        var releaseCount = 0
        let result = decodeOwnedJSON(Payload.self, from: pointer, release: { released in
            releaseCount += 1
            released.deallocate()
        })
        XCTAssertNil(result)
        XCTAssertEqual(releaseCount, 1)
    }

    func testLargeInputBorrowsRustStyleStorageDuringDecode() throws {
        let expected = Payload(ink: String(repeating: "quoted \" café 🦀\n", count: 8192))
        let json = try JSONEncoder().encode(expected)
        let pointer = allocate(Array(json))
        var released = false
        let result = decodeOwnedJSON(Payload.self, from: pointer, release: { allocation in
            released = true
            allocation.deallocate()
        }, decode: { type, data in
            XCTAssertFalse(released)
            data.withUnsafeBytes { bytes in
                XCTAssertEqual(bytes.baseAddress, UnsafeRawPointer(pointer))
                XCTAssertEqual(bytes.count, json.count)
            }
            return try JSONDecoder().decode(type, from: data)
        })
        XCTAssertTrue(released)
        XCTAssertEqual(result, expected)
    }

    func testInjectedDecoderFailureReleasesExactlyOnce() {
        enum Failure: Error { case refused }
        let pointer = allocate(Array("{\"ink\":\"value\"}".utf8))
        var releaseCount = 0
        let result = decodeOwnedJSON(Payload.self, from: pointer, release: { allocation in
            releaseCount += 1
            allocation.deallocate()
        }, decode: { _, _ in
            XCTAssertEqual(releaseCount, 0)
            throw Failure.refused
        })
        XCTAssertNil(result)
        XCTAssertEqual(releaseCount, 1)
    }

    func testRealFFIResponseDecodesThenUsesRustFree() throws {
        companion_init()
        let handle = try XCTUnwrap(UUID().uuidString.withCString { companion_new_ephemeral($0) })
        defer { companion_free(handle) }
        let pointer = try XCTUnwrap(companion_tabs_json(handle))
        var releaseCount = 0
        let tabs = decodeOwnedJSON([TabSummary].self, from: pointer, release: { allocation in
            releaseCount += 1
            companion_string_free(allocation)
        })
        XCTAssertNotNil(tabs)
        XCTAssertEqual(releaseCount, 1)
    }

    func testRustFreeLeavesStaticAndForeignStringsAlone() {
        let ffi = CompanionClient.ffiVersion
        let core = CompanionClient.coreVersion
        companion_string_free(UnsafeMutablePointer(mutating: companion_ffi_version()))
        companion_string_free(UnsafeMutablePointer(mutating: companion_version()))
        companion_string_free(UnsafeMutablePointer(mutating: companion_core_version()))
        XCTAssertEqual(CompanionClient.ffiVersion, ffi)
        XCTAssertEqual(CompanionClient.coreVersion, core)

        let foreign = allocate(Array("foreign".utf8))
        companion_string_free(foreign)
        XCTAssertEqual(String(cString: foreign), "foreign")
        foreign.deallocate()
    }

    func testOnlyTheTwoOwnedHelpersReleaseCoreStrings() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try FileManager.default.subpathsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(files.isEmpty)
        var releases: [String] = []
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains("UnsafeMutablePointer(mutating:"), file)
            for line in text.split(separator: "\n") where line.contains("companion_string_free") {
                releases.append("\(file): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(releases.sorted(), [
            "CompanionKit/CompanionClient.swift: defer { companion_string_free(pointer) }",
            "CompanionKit/CompanionClient.swift: release: (UnsafeMutablePointer<CChar>) -> Void = { companion_string_free($0) },",
        ])
    }
}
