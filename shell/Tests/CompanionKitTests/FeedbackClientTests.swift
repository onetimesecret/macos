import Foundation
import XCTest

@testable import CompanionKit

final class FeedbackClientTests: XCTestCase {
    private final class StubProtocol: URLProtocol, @unchecked Sendable {
        static nonisolated(unsafe) var reply: ((URLRequest) throws -> (Int, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let reply = Self.reply else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            do {
                let (status, data) = try reply(request)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: status,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        override func stopLoading() {}
    }

    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var saved: URLRequest?
        private var savedBody: Data?
        func save(_ request: URLRequest) {
            let body = request.httpBody ?? request.httpBodyStream.flatMap { stream in
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                return data
            }
            lock.lock()
            defer { lock.unlock() }
            saved = request
            savedBody = body
        }
        func read() -> URLRequest? { lock.lock(); defer { lock.unlock() }; return saved }
        func body() -> Data? { lock.lock(); defer { lock.unlock() }; return savedBody }
    }

    private func makeClient() -> FeedbackClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return FeedbackClient(
            serverURL: "https://eu.onetimesecret.com",
            session: URLSession(configuration: configuration),
            timeZone: "America/Vancouver"
        )
    }

    override func tearDown() {
        StubProtocol.reply = nil
        super.tearDown()
    }

    func testPostsLiveFormContractWithoutCredentials() async throws {
        let box = RequestBox()
        StubProtocol.reply = { request in
            box.save(request)
            return (200, Data(#"{"record":{},"details":{"message":"Message received."}}"#.utf8))
        }

        try await makeClient().send(message: "A & B + café", contact: "person+tag@example.test")

        let request = try XCTUnwrap(box.read())
        XCTAssertEqual(request.url?.absoluteString, "https://eu.onetimesecret.com/api/v3/feedback")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        let body = try XCTUnwrap(box.body().flatMap { String(data: $0, encoding: .utf8) })
        let fields = URLComponents(string: "?" + body)?.queryItems ?? []
        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(fields.first(where: { $0.name == "msg" })?.value,
                       "Contact: person+tag@example.test\n\nA & B + café")
        XCTAssertEqual(fields.first(where: { $0.name == "tz" })?.value, "America/Vancouver")
        XCTAssertTrue(body.contains("%2B"), "a literal plus must survive form decoding")
    }

    func testEveryByteOutsideTheUnreservedSetTravelsEscaped() async throws {
        let box = RequestBox()
        StubProtocol.reply = { request in
            box.save(request)
            return (200, Data(#"{"record":{},"details":{"message":"Message received."}}"#.utf8))
        }
        let message = "C++; a & b = c % d / e ? f\né 🙂"

        try await makeClient().send(message: message)

        let body = try XCTUnwrap(box.body().flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertFalse(body.contains(";"), "some form decoders split on a literal semicolon")
        XCTAssertFalse(body.contains("+"), "a form decoder reads a literal plus as a space")
        // What is left literal is the unreserved set, the escapes, and the
        // one '&' and two '=' that are the form's own structure.
        let literal = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~%&="
        )
        XCTAssertTrue(body.unicodeScalars.allSatisfy { literal.contains($0) }, body)
        XCTAssertEqual(body.filter { $0 == "&" }.count, 1)
        XCTAssertEqual(body.filter { $0 == "=" }.count, 2)

        let fields = formDecode(body)
        XCTAssertEqual(fields.map(\.name), ["msg", "tz"])
        XCTAssertEqual(fields.first?.value, message, "the exact message survives a form decode")
        XCTAssertEqual(fields.last?.value, "America/Vancouver")
    }

    /// What an `application/x-www-form-urlencoded` reader does with a
    /// body: split on '&', then on the first '=', read '+' as a space,
    /// then undo the escapes. Stricter than `URLComponents`, which keeps a
    /// '+' as it is and so would pass a body a server reads differently.
    private func formDecode(_ body: String) -> [(name: String, value: String?)] {
        func decode(_ text: Substring) -> String? {
            text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        }
        return body.split(separator: "&", omittingEmptySubsequences: false).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (decode(parts[0]) ?? "", parts.count == 2 ? decode(parts[1]) : nil)
        }
    }

    func testRateLimitAndInvalidAcknowledgementDoNotCountAsSuccess() async {
        StubProtocol.reply = { _ in (429, Data(#"{"message":"retry later"}"#.utf8)) }
        do {
            try await makeClient().send(message: "a report")
            XCTFail("429 must fail")
        } catch {
            XCTAssertEqual(error as? FeedbackClient.Failure, .rateLimited)
        }

        StubProtocol.reply = { _ in (200, Data(#"{"unexpected":"page"}"#.utf8)) }
        do {
            try await makeClient().send(message: "a report")
            XCTFail("a generic 200 must not claim delivery")
        } catch {
            XCTAssertEqual(error as? FeedbackClient.Failure, .invalidResponse)
        }
    }

    func testRejectsEmptyAndOversizedReportsBeforeTransport() async {
        let box = RequestBox()
        StubProtocol.reply = { request in
            box.save(request)
            return (200, Data(#"{"record":{},"details":{"message":"received"}}"#.utf8))
        }
        do {
            try await makeClient().send(message: "  \n ", contact: "person@example.test")
            XCTFail("empty report must fail")
        } catch {
            XCTAssertEqual(error as? FeedbackClient.Failure, .emptyMessage)
        }
        do {
            try await makeClient().send(message: String(repeating: "x", count: 200_001))
            XCTFail("oversized report must fail")
        } catch {
            XCTAssertEqual(error as? FeedbackClient.Failure, .messageTooLong)
        }
        XCTAssertNil(box.read())
    }

    func testRequiresHTTPSAndRejectsServerError() async {
        let badClient = FeedbackClient(serverURL: "http://eu.onetimesecret.com", session: nil)
        XCTAssertNil(badClient.endpointURL)
        do {
            try await badClient.send(message: "a report")
            XCTFail("non-HTTPS destination must fail")
        } catch {
            XCTAssertEqual(error as? FeedbackClient.Failure, .invalidServer)
        }

        StubProtocol.reply = { _ in (500, Data(#"{"message":"private server detail"}"#.utf8)) }
        do {
            try await makeClient().send(message: "a report")
            XCTFail("server error must fail")
        } catch {
            XCTAssertEqual(error as? FeedbackClient.Failure, .rejected)
            XCTAssertFalse(error.localizedDescription.contains("private server detail"))
        }
    }

    func testTransportFailureKeepsResponseTextOutOfError() async {
        StubProtocol.reply = { _ in throw URLError(.cannotConnectToHost) }
        do {
            try await makeClient().send(message: "a report")
            XCTFail("transport failure must fail")
        } catch {
            XCTAssertEqual(error as? FeedbackClient.Failure, .unavailable)
        }
    }
}
