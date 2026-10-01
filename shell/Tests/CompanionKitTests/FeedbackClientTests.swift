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
