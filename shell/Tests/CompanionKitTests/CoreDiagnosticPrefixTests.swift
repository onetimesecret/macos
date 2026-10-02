import Foundation
import XCTest

@testable import CompanionKit

/// The core's diagnostic lines are Rust's to word, and the trail tells
/// four of them apart by prefix alone: nothing at the seam carries a code
/// for them. So these cases read the crates' sources and find each prefix
/// there. Reword one of those messages in Rust and a case here fails,
/// rather than the trail quietly filing the line as a generic fault, or,
/// for the notice, dropping it.
final class CoreDiagnosticPrefixTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // CompanionKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // shell
        .deletingLastPathComponent()  // the repository

    private func rust(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func prefix(for kind: DiagnosticEvents.Kind) throws -> String {
        try XCTUnwrap(DiagnosticEvents.corePrefixes.first { $0.kind == kind }?.prefix)
    }

    /// The value of a `const NAME: &str = "...";` in a Rust source.
    private func constant(_ name: String, in source: String) throws -> String {
        let head = "const \(name): &str = \""
        let start = try XCTUnwrap(source.range(of: head), "\(name) is not a &str const any more")
        let end = try XCTUnwrap(source.range(of: "\"", range: start.upperBound..<source.endIndex))
        return String(source[start.upperBound..<end.lowerBound])
    }

    func testEveryPrefixInTheTableHasACaseHere() {
        // A prefix added to the table without a case below would be the
        // same unchecked coupling this suite exists to close.
        XCTAssertEqual(
            DiagnosticEvents.corePrefixes.map(\.kind),
            [.keychainLoginFallback, .stateKeyRefused, .ledgerKeyRefused, .stateRestoreRefused]
        )
    }

    func testTheKeychainFallbackNoticeOpensWithItsPrefix() throws {
        // The bridge in crates/ffi/src/diagnostics.rs forwards the
        // credentials crate's line as it is, with no tag of its own, so
        // the literal is the whole of the prefix. The opening quote pins
        // it to the start of the string, and the interpolation after it
        // pins where the literal ends.
        let source = try rust("crates/credentials/src/lib.rs")
        let prefix = try prefix(for: .keychainLoginFallback)
        XCTAssertTrue(source.contains("\"" + prefix + "{service}"), prefix)
    }

    func testTheStateFileRefusalsOpenWithTheirPrefix() throws {
        let source = try rust("crates/ffi/src/persist.rs")
        let prefix = try prefix(for: .stateRestoreRefused)
        XCTAssertTrue(source.contains("\"" + prefix), prefix)
    }

    func testTheKeyItemPrefixesAreTheTemplateAroundEachAccountName() throws {
        // Neither line is literal anywhere. `load_key_for` writes the
        // template below and fills `{account}` at run time with one of two
        // constants, so the template and each constant's value are read
        // apart and the Swift prefix is checked to be their composition.
        let source = try rust("crates/ffi/src/persist.rs")
        let template = "companion-ffi: the {account} item "
        XCTAssertTrue(source.contains("\"" + template), template)
        let accounts: [(DiagnosticEvents.Kind, String)] = [
            (.stateKeyRefused, "STATE_KEY_ACCOUNT"),
            (.ledgerKeyRefused, "LEDGER_KEY_ACCOUNT"),
        ]
        for (kind, name) in accounts {
            let account = try constant(name, in: source)
            XCTAssertEqual(
                try prefix(for: kind),
                template.replacingOccurrences(of: "{account}", with: account),
                name
            )
        }
    }
}
