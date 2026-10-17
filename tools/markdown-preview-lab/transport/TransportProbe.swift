import CryptoKit
import Foundation

func emit(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data([10]))
}

struct TestCase: Decodable {
    let id: String
    let url: URL
    let followRedirects: Bool
}

final class Probe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let test: TestCase
    let completed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var byteCount = 0
    private var redirects: [[String: Any]] = []
    private var metrics: [[String: Any]] = []
    private var result: [String: Any] = [:]
    private var started: Date?
    private var session: URLSession!
    private(set) var task: URLSessionDataTask!

    init(test: TestCase) {
        self.test = test
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: test.url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        task = session.dataTask(with: request)
    }

    func activate() {
        lock.lock()
        started = Date()
        lock.unlock()
        emit(["event": "resume", "id": test.id, "url": test.url.absoluteString,
              "followRedirects": test.followRedirects])
        task.resume()
    }

    func finish() -> [String: Any] {
        if completed.wait(timeout: .now() + 35) == .timedOut {
            task.cancel()
            session.invalidateAndCancel()
            return ["event": "result", "id": test.id, "driverWaitTimedOut": true]
        }
        session.finishTasksAndInvalidate()
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        byteCount += data.count
        let tooLarge = byteCount > 65_536
        lock.unlock()
        if tooLarge { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.lock()
        let follow = test.followRedirects && redirects.count < 5
        redirects.append(["status": response.statusCode,
                          "from": response.url?.absoluteString ?? "",
                          "to": request.url?.absoluteString ?? "", "followed": follow])
        lock.unlock()
        completionHandler(follow ? request : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting collected: URLSessionTaskMetrics) {
        let transactions: [[String: Any]] = collected.transactionMetrics.map { item in
            var entry: [String: Any] = [
                "url": item.request.url?.absoluteString ?? "",
                "fetchType": item.resourceFetchType.rawValue,
                "proxyConnection": item.isProxyConnection,
                "reusedConnection": item.isReusedConnection,
                "dnsStarted": item.domainLookupStartDate != nil,
                "connectStarted": item.connectStartDate != nil,
                "tlsStarted": item.secureConnectionStartDate != nil,
                "requestStarted": item.requestStartDate != nil,
                "requestHeaderBytesSent": item.countOfRequestHeaderBytesSent,
                "responseBodyBytesReceived": item.countOfResponseBodyBytesReceived,
            ]
            if let value = item.networkProtocolName { entry["protocol"] = value }
            if let value = item.remoteAddress { entry["remoteAddress"] = value }
            if let value = item.negotiatedTLSProtocolVersion {
                entry["tlsProtocolVersion"] = String(describing: value)
            }
            if let response = item.response as? HTTPURLResponse { entry["status"] = response.statusCode }
            return entry
        }
        lock.lock()
        metrics = transactions
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        result = ["event": "result", "id": test.id, "url": test.url.absoluteString,
                  "followRedirects": test.followRedirects, "bytesReceived": byteCount,
                  "redirects": redirects, "transactions": metrics,
                  "elapsedSeconds": Date().timeIntervalSince(started ?? Date())]
        if let response = task.response as? HTTPURLResponse {
            result["status"] = response.statusCode
            result["finalURL"] = response.url?.absoluteString
            result["location"] = response.value(forHTTPHeaderField: "Location")
        }
        if let error {
            let ns = error as NSError
            result["error"] = ["domain": ns.domain, "code": ns.code,
                               "description": ns.localizedDescription]
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                result["underlyingError"] = ["domain": underlying.domain, "code": underlying.code]
            }
        }
        lock.unlock()
        completed.signal()
    }
}

@main
struct TransportProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("Usage: OnetimePad cases.json; send ACTIVATE on stdin")
        }
        let bundle = Bundle.main
        let plistURL = bundle.bundleURL.appendingPathComponent("Contents/Info.plist")
        guard bundle.bundleURL.pathExtension == "app",
              bundle.executableURL?.lastPathComponent == "OnetimePad",
              bundle.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String == "com.onetimesecret.pad",
              bundle.object(forInfoDictionaryKey: "NSAppTransportSecurity") == nil else {
            fatalError("Expected the isolated app bundle with the unmodified current plist")
        }
        let plist = try Data(contentsOf: plistURL)
        let tests = try JSONDecoder().decode([TestCase].self,
                    from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let probes = tests.map(Probe.init)
        emit(["event": "prepared", "bundlePath": bundle.bundlePath,
              "executablePath": bundle.executablePath ?? "",
              "bundleIdentifier": bundle.bundleIdentifier ?? "",
              "plistSHA256": SHA256.hash(data: plist).map { String(format: "%02x", $0) }.joined(),
              "atsDictionaryPresent": false,
              "runtimeOS": ProcessInfo.processInfo.operatingSystemVersionString,
              "session": ["configuration": "ephemeral", "cookieStorageNil": true,
                          "shouldSetCookies": false, "credentialStorageNil": true,
                          "urlCacheNil": true, "cachePolicy": "reloadIgnoringLocalCacheData",
                          "requestTimeoutSeconds": 20, "resourceTimeoutSeconds": 30],
              "suspendedTaskCount": probes.count,
              "allTasksSuspended": probes.allSatisfy { $0.task.state == .suspended }])
        guard readLine() == "ACTIVATE" else {
            emit(["event": "aborted", "reason": "No explicit ACTIVATE command"])
            return
        }
        emit(["event": "activated"])
        for probe in probes {
            probe.activate()
            emit(probe.finish())
        }
        emit(["event": "complete", "caseCount": probes.count])
    }
}
