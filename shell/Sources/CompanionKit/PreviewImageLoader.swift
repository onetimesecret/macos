import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PreviewImageRequestPolicy {
    static let maximumBytes = 5 * 1_024 * 1_024
    static let maximumPixels = 16_000_000
    static let maximumDimension = 8_192
    static let maximumAddressBytes = 8_192
    static let timeout: TimeInterval = 15

    static func url(for destination: PreviewAddress) -> URL? {
        guard case .unreviewed(let address) = destination,
              address.utf8.count <= maximumAddressBytes,
              address.unicodeScalars.allSatisfy({
                  !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
              }),
              var parts = URLComponents(string: address),
              parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(), validHost(host)
        else { return nil }
        parts.percentEncodedHost = host
        parts.fragment = nil
        parts.port = nil
        return parts.url
    }

    static func refusal(for destination: PreviewAddress) -> String? {
        url(for: destination) == nil
            ? CompanionL10n.string("Images require an absolute HTTPS address with a DNS hostname, no credentials, and the standard HTTPS port. Local names and IP addresses are unavailable.")
            : nil
    }

    private static func validHost(_ host: String) -> Bool {
        guard !host.hasSuffix("."), host.utf8.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              !["localhost", "local", "internal", "home", "lan", "test", "invalid", "arpa",
                "onion", "i2p", "alt", "localdomain"].contains(String(labels.last!)),
              labels.last!.utf8.contains(where: { (97...122).contains($0) })
        else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
}

enum PreviewImageLoadError: Error, Equatable, LocalizedError {
    case invalidURL, response, tooLarge, unsupportedFormat, invalidImage, dimensions
    case redirected, authentication, cancelled

    var errorDescription: String? {
        let key: String
        switch self {
        case .invalidURL: key = "This image address is unavailable."
        case .response: key = "The server did not return an image."
        case .tooLarge: key = "The image exceeds the 5 MiB download limit."
        case .unsupportedFormat: key = "Only PNG, JPEG, and GIF images can be loaded."
        case .invalidImage: key = "The image could not be decoded."
        case .dimensions: key = "The image exceeds the dimension limit."
        case .redirected: key = "The image request redirected. Redirects are unavailable."
        case .authentication: key = "The image requires authentication."
        case .cancelled: key = "Image loading was cancelled."
        }
        return CompanionL10n.string(key)
    }
}

@MainActor
final class PreviewImageLoader {
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration.copy() as? URLSessionConfiguration ?? .ephemeral
    }

    func load(_ url: URL) async throws -> NSImage {
        guard let approved = PreviewImageRequestPolicy.url(for: .unreviewed(url.absoluteString)) else {
            throw PreviewImageLoadError.invalidURL
        }
        let config = configuration.copy() as? URLSessionConfiguration ?? .ephemeral
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = PreviewImageRequestPolicy.timeout
        config.timeoutIntervalForResource = PreviewImageRequestPolicy.timeout
        config.httpAdditionalHeaders = nil
        var request = URLRequest(url: approved)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = PreviewImageRequestPolicy.timeout
        request.setValue("image/png, image/jpeg, image/gif", forHTTPHeaderField: "Accept")
        request.setValue("OnetimePad-ImagePreview", forHTTPHeaderField: "User-Agent")
        request.setValue("*", forHTTPHeaderField: "Accept-Language")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let transfer = PreviewImageTransfer()
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfer.start(request: request, configuration: config, continuation: continuation)
            }
        } onCancel: {
            transfer.cancel()
        }
        try Task.checkCancellation()
        let image = try await PreviewImageDecoder.shared.decode(data)
        try Task.checkCancellation()
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    nonisolated static func decodePixelImage(_ data: Data) throws -> CGImage {
        guard data.count <= PreviewImageRequestPolicy.maximumBytes else { throw PreviewImageLoadError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) else { throw PreviewImageLoadError.invalidImage }
        guard [UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier].contains(type as String) else {
            throw PreviewImageLoadError.unsupportedFormat
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw PreviewImageLoadError.invalidImage }
        guard width <= PreviewImageRequestPolicy.maximumDimension,
              height <= PreviewImageRequestPolicy.maximumDimension,
              width <= PreviewImageRequestPolicy.maximumPixels / height else { throw PreviewImageLoadError.dimensions }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_600,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PreviewImageLoadError.invalidImage
        }
        return image
    }
}

actor PreviewImageDecoder {
    static let shared = PreviewImageDecoder()

    func decode(_ data: Data) throws -> CGImage {
        try Task.checkCancellation()
        return try autoreleasepool { try PreviewImageLoader.decodePixelImage(data) }
    }
}

private final class PreviewImageTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var bytes = Data()
    private var finished = false

    func start(
        request: URLRequest, configuration: URLSessionConfiguration,
        continuation: CheckedContinuation<Data, any Error>
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: PreviewImageLoadError.cancelled)
            return
        }
        self.continuation = continuation
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        lock.unlock()
        task.resume()
    }

    func cancel() { finish(.failure(PreviewImageLoadError.cancelled)) }

    private func finish(_ result: Result<Data, any Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        task = nil
        bytes = Data()
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            completionHandler(.cancel)
            finish(.failure(PreviewImageLoadError.response))
            return
        }
        guard ["image/png", "image/jpeg", "image/gif"].contains(response.mimeType?.lowercased() ?? "") else {
            completionHandler(.cancel)
            finish(.failure(PreviewImageLoadError.unsupportedFormat))
            return
        }
        guard response.expectedContentLength <= Int64(PreviewImageRequestPolicy.maximumBytes) else {
            completionHandler(.cancel)
            finish(.failure(PreviewImageLoadError.tooLarge))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard data.count <= PreviewImageRequestPolicy.maximumBytes - bytes.count else {
            lock.unlock()
            finish(.failure(PreviewImageLoadError.tooLarge))
            return
        }
        bytes.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { finish(.failure(error)); return }
        lock.lock()
        let data = bytes
        lock.unlock()
        finish(.success(data))
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        finish(.failure(PreviewImageLoadError.redirected))
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        respond(to: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        respond(to: challenge, completionHandler: completionHandler)
    }

    private func respond(
        to challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            finish(.failure(PreviewImageLoadError.authentication))
        }
    }
}
