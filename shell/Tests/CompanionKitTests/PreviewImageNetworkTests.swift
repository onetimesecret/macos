import AppKit
import CFNetwork
import XCTest

@testable import CompanionKit

@MainActor
final class PreviewImageNetworkTests: XCTestCase {
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
        let report = try await exercise("tunnel") { loader in
            let image = try await loader.load(URL(string:
                "https://raw.githubusercontent.com/github/explore/main/topics/swift/swift.png")!)
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertGreaterThan(image.size.height, 0)
        }
        XCTAssertGreaterThan(try XCTUnwrap(report["tunneled_bytes"] as? Int), 0)
    }

    private func exercise(
        _ mode: String, operation: (PreviewImageLoader) async throws -> Void
    ) async throws -> [String: Any] {
        guard ProcessInfo.processInfo.environment["PREVIEW_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Set PREVIEW_NETWORK_TESTS=1 for controlled loopback sockets and one public HTTPS image")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("preview-network-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        if mode == "untrustedTLS" {
            let certificate = Process()
            certificate.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            certificate.arguments = [
                "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                "-subj", "/CN=preview-validation.example.com", "-keyout", folder.appendingPathComponent("key.pem").path,
                "-out", folder.appendingPathComponent("cert.pem").path,
            ]
            certificate.standardOutput = FileHandle.nullDevice
            certificate.standardError = FileHandle.nullDevice
            try certificate.run()
            certificate.waitUntilExit()
            XCTAssertEqual(certificate.terminationStatus, 0)
        }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/preview-image-proxy-fixture.py")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [fixture.path, mode, folder.path]
        try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
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
        let finishDeadline = Date().addingTimeInterval(5)
        while server.isRunning, Date() < finishDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(server.isRunning, "Proxy fixture did not finish")
        let data = try Data(contentsOf: folder.appendingPathComponent("report.json"))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(report["error"], "\(report)")
        return report
    }
}
