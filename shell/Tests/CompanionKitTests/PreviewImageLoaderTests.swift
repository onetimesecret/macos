import AppKit
import ImageIO
import XCTest

@testable import CompanionKit

@MainActor
final class PreviewImageLoaderTests: XCTestCase {
    private final class StubProtocol: URLProtocol, @unchecked Sendable {
        static nonisolated(unsafe) var reply: ((URLRequest, any URLProtocolClient, URLProtocol) -> Void)?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let client else { return }
            Self.reply?(request, client, self)
        }
        override func stopLoading() {}
    }

    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func set(_ value: Value) { lock.lock(); self.value = value; lock.unlock() }
        func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
        func update(_ operation: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; operation(&value) }
    }

    private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
        func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
        func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
    }

    private func loader() -> PreviewImageLoader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        configuration.httpAdditionalHeaders = ["Authorization": "Bearer forbidden", "Referer": "https://forbidden.example/"]
        return PreviewImageLoader(configuration: configuration)
    }

    private func fixture(
        _ format: NSBitmapImageRep.FileType = .png, width: Int = 4, height: Int = 3, fill: UInt8 = 0
    ) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width * 3, bitsPerPixel: 24))
        bitmap.bitmapData?.initialize(repeating: fill, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        return try XCTUnwrap(bitmap.representation(using: format, properties: [:]))
    }

    private func reply(status: Int = 200, mime: String = "image/png", data: Data, length: Int? = nil) {
        StubProtocol.reply = { request, client, stub in
            var headers = ["Content-Type": mime]
            if let length { headers["Content-Length"] = String(length) }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client.urlProtocol(stub, didReceive: response, cacheStoragePolicy: .notAllowed)
            for start in stride(from: 0, to: data.count, by: 65_536) {
                client.urlProtocol(stub, didLoad: data.subdata(in: start..<min(start + 65_536, data.count)))
            }
            client.urlProtocolDidFinishLoading(stub)
        }
    }

    private func failure(_ expected: PreviewImageLoadError, url: String = "https://images.example.com/picture") async {
        do {
            _ = try await loader().load(URL(string: url)!)
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? PreviewImageLoadError, expected)
        }
    }

    func testAddressPolicyRefusesLocalRelativeCredentialsAndAlternatePorts() {
        for address in [
            "http://images.example.com/a", "file:///tmp/a.png", "data:image/png;base64,a", "/a.png",
            "//images.example.com/a", "https://localhost/a", "https://printer.local/a",
            "https://printer/a", "https://home.internal/a", "https://127.0.0.1/a",
            "https://2130706433/a", "https://0177.0.0.1/a", "https://[::1]/a",
            "https://user:password@images.example.com/a", "https://images.example.com:444/a",
            "https://images.example.com./a", "https://-bad.example.com/a",
            "https://router.home.arpa/a", "https://1.0.0.127.in-addr.arpa/a", "https://arpa/a",
        ] {
            XCTAssertNil(PreviewImageRequestPolicy.url(for: .unreviewed(address)), address)
            XCTAssertNotNil(PreviewImageRequestPolicy.refusal(for: .unreviewed(address)), address)
        }
        XCTAssertNil(PreviewImageRequestPolicy.url(for: .refused(.sealedObject)))
        XCTAssertNil(PreviewImageRequestPolicy.url(for: .refused(.missing)))
        XCTAssertEqual(PreviewImageRequestPolicy.url(for: .unreviewed("https://images.example.com:443/a#fragment"))?.absoluteString,
                       "https://images.example.com/a")
        XCTAssertNil(PreviewImageRequestPolicy.refusal(for: .unreviewed("https://images.example.com/a")))
    }

    func testLoadMakesOneCredentialFreeGETAndDecodesPNG() async throws {
        let image = try fixture()
        let requests = Box<[URLRequest]>([])
        StubProtocol.reply = { request, client, stub in
            requests.set(requests.get() + [request])
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
            client.urlProtocol(stub, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(stub, didLoad: image)
            client.urlProtocolDidFinishLoading(stub)
        }
        let decoded = try await loader().load(URL(string: "https://images.example.com/a#fragment")!)
        XCTAssertEqual(decoded.size, NSSize(width: 4, height: 3))
        let request = try XCTUnwrap(requests.get().first)
        XCTAssertEqual(requests.get().count, 1)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://images.example.com/a")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "image/png, image/jpeg, image/gif")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "OnetimePad-ImagePreview")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), "*")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.timeoutInterval, 15)
    }

    func testValidatedHostnameIsCanonicalInPolicyAndTransportURLs() async throws {
        let image = try fixture()
        let requests = Box<[URLRequest]>([])
        StubProtocol.reply = { request, client, stub in
            requests.set(requests.get() + [request])
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/png"])!
            client.urlProtocol(stub, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(stub, didLoad: image)
            client.urlProtocolDidFinishLoading(stub)
        }
        let loader = loader()
        let addresses = [
            "https://IMAGES.Example.COM/a",
            "https://%69mages.example.com/a",
            "https://images.%65xample.com:443/a#fragment",
        ]
        for address in addresses {
            let approved = try XCTUnwrap(PreviewImageRequestPolicy.url(for: .unreviewed(address)))
            XCTAssertEqual(approved.absoluteString, "https://images.example.com/a")
            XCTAssertEqual(approved.host, "images.example.com")
            let url = try XCTUnwrap(URL(string: address))
            _ = try await loader.load(url)
        }
        XCTAssertEqual(requests.get().count, addresses.count)
        for request in requests.get() {
            XCTAssertEqual(request.url?.absoluteString, "https://images.example.com/a")
            XCTAssertEqual(request.url?.host, "images.example.com")
        }
    }

    func testAddressPolicyRejectsRawWhitespaceControlsAndOversizedAddresses() {
        for suffix in [" a.png", "\ta.png", "\na.png", "\ra.png", "\u{0}a.png", "\u{7F}a.png", "\u{A0}a.png"] {
            XCTAssertNil(PreviewImageRequestPolicy.url(for: .unreviewed("https://images.example.com/" + suffix)))
        }
        let prefix = "https://images.example.com/"
        let address = prefix + String(repeating: "a", count: PreviewImageRequestPolicy.maximumAddressBytes - prefix.utf8.count)
        XCTAssertNotNil(PreviewImageRequestPolicy.url(for: .unreviewed(address)))
        XCTAssertNil(PreviewImageRequestPolicy.url(for: .unreviewed(address + "a")))
        XCTAssertEqual(PreviewImageRequestPolicy.url(for: .unreviewed(prefix + "an%20image.png"))?.absoluteString,
                       prefix + "an%20image.png")
    }

    func testUnicodeHostnameAndItsPunycodeSpellingHaveExplicitPolicyResults() {
        XCTAssertNil(PreviewImageRequestPolicy.url(for: .unreviewed("https://bücher.example/a")))
        XCTAssertNil(PreviewImageRequestPolicy.url(for: .unreviewed("https://xn--bcher-kva.example/a")))
    }

    func testServerCookieIsNotReusedForAnotherExplicitLoad() async throws {
        let data = try fixture()
        let requests = Box<[URLRequest]>([])
        StubProtocol.reply = { request, client, stub in
            requests.set(requests.get() + [request])
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/png", "Set-Cookie": "image_session=forbidden; Secure; Path=/"])!
            client.urlProtocol(stub, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(stub, didLoad: data)
            client.urlProtocolDidFinishLoading(stub)
        }
        let loader = loader()
        for _ in 0..<2 { _ = try await loader.load(URL(string: "https://images.example.com/a")!) }
        XCTAssertEqual(requests.get().count, 2)
        for request in requests.get() { XCTAssertNil(request.value(forHTTPHeaderField: "Cookie")) }
    }

    func testRefusedURLNeverReachesTransport() async {
        let contacted = Box(false)
        StubProtocol.reply = { _, _, _ in contacted.set(true) }
        await failure(.invalidURL, url: "https://127.0.0.1/picture")
        XCTAssertFalse(contacted.get())
    }

    func testStatusAndContentTypeAreRequired() async throws {
        reply(status: 404, data: try fixture())
        await failure(.response)
        reply(mime: "text/html", data: try fixture())
        await failure(.unsupportedFormat)
    }

    func testAdvertisedAndStreamingLimitsBothRefuse() async throws {
        reply(data: try fixture(), length: PreviewImageRequestPolicy.maximumBytes + 1)
        await failure(.tooLarge)
        reply(data: Data(repeating: 0, count: PreviewImageRequestPolicy.maximumBytes + 1))
        await failure(.tooLarge)
    }

    func testInvalidAndUnsupportedImageDataRefuse() async throws {
        reply(data: Data("not an image".utf8))
        await failure(.invalidImage)
        reply(data: try fixture(.tiff))
        await failure(.unsupportedFormat)
    }

    func testDimensionAndPixelLimitsApplyBeforeFullDecode() throws {
        XCTAssertThrowsError(try PreviewImageLoader.decode(fixture(width: 8_193, height: 1))) {
            XCTAssertEqual($0 as? PreviewImageLoadError, .dimensions)
        }
        XCTAssertThrowsError(try PreviewImageLoader.decode(fixture(width: 4_001, height: 4_000))) {
            XCTAssertEqual($0 as? PreviewImageLoadError, .dimensions)
        }
    }

    func testSupportedFormatsDecodeAndLargeAllowedImageIsDownsampled() throws {
        for format in [NSBitmapImageRep.FileType.png, .jpeg, .gif] {
            XCTAssertEqual(try PreviewImageLoader.decode(fixture(format)).size, NSSize(width: 4, height: 3))
        }
        let downsampled = try PreviewImageLoader.decode(fixture(width: 3_200, height: 400))
        XCTAssertEqual(downsampled.size, NSSize(width: 1_600, height: 200))
    }

    func testAnimatedGIFBecomesOnlyItsFirstStaticFrame() throws {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, "com.compuserve.gif" as CFString, 2, nil))
        for fill in [UInt8(0), UInt8(255)] {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(fixture(fill: fill) as CFData, nil))
            let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1],
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        let decoded = try PreviewImageLoader.decode(data as Data)
        XCTAssertEqual(decoded.representations.count, 1)
        let frame = try XCTUnwrap(decoded.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let pixel = try XCTUnwrap(NSBitmapImageRep(cgImage: frame).colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(pixel.redComponent, 0.01)
        XCTAssertLessThan(pixel.greenComponent, 0.01)
        XCTAssertLessThan(pixel.blueComponent, 0.01)
    }

    func testSharedDecoderRunsOffMainAndSerializesConcurrentImages() async throws {
        let data = try fixture(width: 3_200, height: 400)
        let observation = Box((active: 0, maximum: 0, mainThread: false, started: 0))
        let observe: @Sendable (Bool, Bool) -> Void = { starting, mainThread in
            observation.update { state in
                state.mainThread = state.mainThread || mainThread
                if starting {
                    state.active += 1
                    state.started += 1
                    state.maximum = max(state.maximum, state.active)
                } else {
                    state.active -= 1
                }
            }
        }
        async let first = PreviewImageDecoder.shared.decodeObservedForTest(data, observe: observe)
        async let second = PreviewImageDecoder.shared.decodeObservedForTest(data, observe: observe)
        async let third = PreviewImageDecoder.shared.decodeObservedForTest(data, observe: observe)
        let images = try await [first, second, third]
        for image in images {
            XCTAssertEqual(image.width, 1_600)
            XCTAssertEqual(image.height, 200)
        }
        let state = observation.get()
        XCTAssertFalse(state.mainThread)
        XCTAssertEqual(state.maximum, 1)
        XCTAssertEqual(state.started, 3)
        XCTAssertEqual(state.active, 0)
    }

    func testCancellingSuspendedLoadCompletesWithoutAnImage() async throws {
        let started = expectation(description: "request started")
        StubProtocol.reply = { _, _, _ in started.fulfill() }
        let task = Task { try await loader().load(URL(string: "https://images.example.com/a")!) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation returned an image") }
        catch { XCTAssertEqual(error as? PreviewImageLoadError, .cancelled) }
    }

    func testRedirectDoesNotContactItsDestination() async {
        let requests = Box<[URLRequest]>([])
        StubProtocol.reply = { request, client, stub in
            requests.set(requests.get() + [request])
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": "https://other.example.com/next"])!
            client.urlProtocol(stub, wasRedirectedTo: URLRequest(url: URL(string: "https://other.example.com/next")!), redirectResponse: response)
        }
        await failure(.redirected)
        XCTAssertEqual(requests.get().count, 1)
        XCTAssertEqual(requests.get().first?.url?.host, "images.example.com")
    }

    func testCredentialChallengeIsRefused() async {
        StubProtocol.reply = { _, client, stub in
            let space = URLProtectionSpace(
                host: "images.example.com", port: 443, protocol: "https", realm: "image",
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
            let challenge = URLAuthenticationChallenge(
                protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
                failureResponse: nil, error: nil, sender: ChallengeSender())
            client.urlProtocol(stub, didReceive: challenge)
        }
        await failure(.authentication)
    }
}

private extension PreviewImageDecoder {
    func decodeObservedForTest(_ data: Data, observe: @Sendable (Bool, Bool) -> Void) throws -> CGImage {
        observe(true, Thread.isMainThread)
        defer { observe(false, Thread.isMainThread) }
        return try decode(data)
    }
}
