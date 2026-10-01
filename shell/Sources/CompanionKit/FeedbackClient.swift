import Foundation

/// Sends a report only when the caller invokes `send`. The server's live
/// feedback handler reads URL-encoded `msg` and `tz` fields; it does not read
/// the `message` and `email` fields in the current TypeScript request schema.
public struct FeedbackClient: Sendable {
    public static let maximumMessageLength = 200_000

    public enum Failure: Error, LocalizedError, Equatable {
        case invalidServer
        case emptyMessage
        case messageTooLong
        case rateLimited
        case rejected
        case unavailable
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .invalidServer: "Configure a valid HTTPS server URL in Settings."
            case .emptyMessage: "Write a message or include diagnostics before sending."
            case .messageTooLong: "This report is too long. Shorten it and try again."
            case .rateLimited: "Too many reports were sent recently. Please try again later."
            case .rejected: "The server could not accept this report. Please try again later."
            case .unavailable: "The server could not be reached. Check your connection and try again."
            case .invalidResponse: "The server returned an unexpected response. Please try again later."
            }
        }
    }

    private let serverURL: String
    private let injectedSession: URLSession?
    private let timeZone: String

    /// The exact destination shown in the confirmation surface.
    public var endpointURL: URL? {
        guard let base = URL(string: serverURL),
              base.scheme?.lowercased() == "https",
              base.host != nil,
              base.user == nil,
              base.password == nil,
              base.query == nil,
              base.fragment == nil else { return nil }
        return base.appending(path: "api/v3/feedback")
    }

    /// The normal session keeps no cookies, credentials, or cached response.
    /// Tests can inject a URLProtocol-backed session without contacting a host.
    public init(serverURL: String, session: URLSession? = nil, timeZone: String = TimeZone.current.identifier) {
        self.serverURL = serverURL
        self.timeZone = timeZone
        self.injectedSession = session
    }

    public func send(message: String, contact: String? = nil) async throws {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let contact = contact?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { throw Failure.emptyMessage }
        // The live handler has no email field. A voluntarily supplied contact
        // address is part of the report text so it can reach the recipient.
        let report = contact.isEmpty ? trimmed : "Contact: \(contact)\n\n\(trimmed)"
        guard report.unicodeScalars.count <= Self.maximumMessageLength else {
            throw Failure.messageTooLong
        }
        guard let endpoint = endpointURL else {
            throw Failure.invalidServer
        }
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "msg", value: report),
            URLQueryItem(name: "tz", value: String(timeZone.prefix(64))),
        ]
        // URLComponents leaves '+' literal, while form decoders interpret it
        // as a space. Escape it explicitly so addresses and C++ survive.
        guard let body = form.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .data(using: .utf8) else {
            throw Failure.invalidResponse
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        let session = injectedSession ?? Self.makeSession()
        defer {
            if injectedSession == nil { session.finishTasksAndInvalidate() }
        }
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.unavailable
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        if http.statusCode == 429 { throw Failure.rateLimited }
        guard (200..<300).contains(http.statusCode) else { throw Failure.rejected }
        // V3 has no `success` flag. Require the endpoint's acknowledgement
        // rather than mistaking an unrelated 2xx HTML page for delivery.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["record"] is [String: Any],
              let details = object["details"] as? [String: Any],
              details["message"] is String else {
            throw Failure.invalidResponse
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(
            configuration: configuration,
            delegate: FeedbackNoRedirectDelegate(),
            delegateQueue: nil
        )
    }
}

private final class FeedbackNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
