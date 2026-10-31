import AppKit
import CFNetwork
import CryptoKit
import Darwin
import XCTest

@testable import CompanionKit

@MainActor
final class PreviewImageNetworkTests: XCTestCase {
    private static let imageURL = URL(string:
        "https://raw.githubusercontent.com/github/explore/c8d7bc516928a4f17845b767884a80cc53affd57/topics/swift/swift.png")!
    private static let imageSHA256 = "e2d6999828a626f0fc23dc315b2856144ed4425579073f786218367bcb2dfd27"

    func testLoopbackProxyAuthenticationIsRefusedWithoutCredentials() async throws {
        let report = try await exercise("authentication") { loader in
            do {
                _ = try await loader.load(URL(string: "https://preview-validation.example.com/image.png")!)
                XCTFail("Proxy authentication returned an image")
            } catch {
                XCTAssertEqual(error as? PreviewImageLoadError, .authentication)
            }
        }
        let connect = try XCTUnwrap(report["connect"] as? String)
        XCTAssertTrue(connect.hasPrefix("CONNECT preview-validation.example.com:443 HTTP/1.1\r\n"))
        XCTAssertFalse(connect.lowercased().contains("proxy-authorization:"))
        XCTAssertFalse(connect.lowercased().contains("cookie:"))
    }

    func testLoopbackTunnelDoesNotChangePlatformTLSTrust() async throws {
        let report = try await exercise("untrustedTLS") { loader in
            do {
                _ = try await loader.load(URL(string: "https://preview-validation.example.com/image.png")!)
                XCTFail("Untrusted certificate returned an image")
            } catch {
                XCTAssertEqual((error as NSError).domain, NSURLErrorDomain)
                XCTAssertEqual((error as NSError).code, NSURLErrorServerCertificateUntrusted)
            }
        }
        XCTAssertEqual(report["tls_rejected"] as? Bool, true)
        XCTAssertNil(report["http_after_tls"])
    }

    func testExplicitProxyTunnelLoadsPNGWithDefaultTLSTrust() async throws {
        try requireOptIn()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = PreviewImageRequestPolicy.timeout
        configuration.timeoutIntervalForResource = PreviewImageRequestPolicy.timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: Self.imageURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(response.mimeType, "image/png")
        XCTAssertEqual(data.count, 8_926)
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), Self.imageSHA256)
        let reference = try PreviewImageLoader.decodePixelImage(data)
        let referencePixels = try XCTUnwrap(reference.dataProvider?.data) as Data
        let report = try await exercise("tunnel") { loader in
            let image = try await loader.load(Self.imageURL)
            XCTAssertEqual(image.size, NSSize(width: 288, height: 288))
            let pixels = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.dataProvider?.data) as Data
            XCTAssertEqual(SHA256.hash(data: pixels), SHA256.hash(data: referencePixels))
        }
        XCTAssertGreaterThan(try XCTUnwrap(report["tunneled_bytes"] as? Int), 0)
    }

    private func requireOptIn() throws {
        guard ProcessInfo.processInfo.environment["PREVIEW_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set PREVIEW_NETWORK_TESTS=1 for controlled loopback sockets and a pinned public HTTPS image")
        }
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return !process.isRunning
    }

    private func stop(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        if !(await waitForExit(process, timeout: 2)) {
            kill(process.processIdentifier, SIGKILL)
            _ = await waitForExit(process, timeout: 2)
        }
    }

    private func exercise(
        _ mode: String, operation: (PreviewImageLoader) async throws -> Void
    ) async throws -> [String: Any] {
        try requireOptIn()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("preview-network-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let logURL = folder.appendingPathComponent("fixture.log")
        try Data().write(to: logURL)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        if mode == "untrustedTLS" {
            let certificate = Process()
            certificate.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            certificate.arguments = [
                "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                "-subj", "/CN=preview-validation.example.com", "-keyout", folder.appendingPathComponent("key.pem").path,
                "-out", folder.appendingPathComponent("cert.pem").path,
            ]
            certificate.standardOutput = log
            certificate.standardError = log
            try certificate.run()
            let finished = await waitForExit(certificate, timeout: 5)
            if !finished { await stop(certificate) }
            guard finished, certificate.terminationStatus == 0 else {
                let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "No certificate diagnostics"
                throw NSError(domain: "PreviewImageNetworkTests", code: 1, userInfo: [NSLocalizedDescriptionKey: output])
            }
        }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/preview-image-proxy-fixture.py")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [fixture.path, mode, folder.path]
        server.standardOutput = log
        server.standardError = log
        try server.run()
        var operationError: (any Error)?
        do {
            let deadline = Date().addingTimeInterval(5)
            let portFile = folder.appendingPathComponent("port")
            while !FileManager.default.fileExists(atPath: portFile.path), Date() < deadline, server.isRunning {
                try await Task.sleep(for: .milliseconds(10))
            }
            let port = try XCTUnwrap(Int(String(contentsOf: portFile, encoding: .utf8)))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPSPort as String: port,
            ]
            try await operation(PreviewImageLoader(configuration: configuration))
        } catch {
            operationError = error
        }
        let finished = await waitForExit(server, timeout: 7)
        if !finished { await stop(server) }
        let reportURL = folder.appendingPathComponent("report.json")
        let reportText = (try? String(contentsOf: reportURL, encoding: .utf8)) ?? "No fixture report"
        let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "No process diagnostics"
        let status = server.isRunning ? "still running" : "exit \(server.terminationStatus) / \(server.terminationReason.rawValue)"
        let diagnostic = "Proxy fixture \(mode): \(status), normal completion=\(finished). \(reportText)\n\(output)"
        XCTAssertTrue(finished, diagnostic)
        XCTAssertFalse(server.isRunning, diagnostic)
        if !server.isRunning { XCTAssertEqual(server.terminationStatus, 0, diagnostic) }
        if let operationError {
            XCTFail("Image operation failed: \(operationError). \(diagnostic)")
            throw operationError
        }
        guard let data = reportText.data(using: .utf8),
              let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "PreviewImageNetworkTests", code: 2, userInfo: [NSLocalizedDescriptionKey: diagnostic])
        }
        XCTAssertNil(report["error"], diagnostic)
        XCTAssertEqual(report["phase"] as? String, "finished", diagnostic)
        return report
    }
}
