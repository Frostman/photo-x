import XCTest
@testable import PhotoX

/// Coverage for the PostHog uploader. Uses a custom `URLProtocol`
/// stub so tests never touch the network — every request is
/// intercepted, captured for inspection, and answered with a
/// caller-defined response.
final class TelemetryUploaderTests: XCTestCase {

    private func makeStore(name: String = UUID().uuidString) -> UserDefaults {
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return store
    }

    /// URLSession configured to route through our stub protocol.
    private func makeStubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self] + (config.protocolClasses ?? [])
        return URLSession(configuration: config)
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    // MARK: - empty key short-circuits

    func test_flush_emptyApiKey_returnsFailure_noNetworkCall() async {
        let uploader = TelemetryUploader(
            apiKey: "",
            session: makeStubbedSession(),
            defaults: makeStore()
        )
        let result = await uploader.flush(
            counters: .zero, firstLaunchAt: Date(),
            appVersion: "0.0.1", osVersion: "15.4"
        )
        XCTAssertFalse(result.success)
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 0,
                       "no-op path must not hit the network")
    }

    // MARK: - body shape

    func test_flush_buildsCorrectPostHogPayload() async throws {
        StubURLProtocol.responseStatus = 200
        let store = makeStore()
        let uploader = TelemetryUploader(
            apiKey: "phc_test_key_42",
            session: makeStubbedSession(),
            defaults: store
        )
        let counters = UsageMetrics.Counters(
            appOpens: 142, photosSeen: 9831, shootsOpened: 12,
            exportsCompleted: 4, imagesExported: 87, scoresSet: 2103
        )
        let firstLaunch = ISO8601DateFormatter().date(from: "2026-05-23T07:00:00Z")!

        let result = await uploader.flush(
            counters: counters, firstLaunchAt: firstLaunch,
            appVersion: "0.267.0", osVersion: "15.4"
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.httpStatus, 200)
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1)

        let req = StubURLProtocol.capturedRequests[0]
        XCTAssertEqual(req.url?.absoluteString, "https://us.i.posthog.com/capture/")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(StubURLProtocol.capturedBodies[0])
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual(obj["api_key"] as? String, "phc_test_key_42")
        XCTAssertEqual(obj["event"] as? String, "usage_snapshot")
        XCTAssertNotNil(obj["distinct_id"] as? String)

        let props = obj["properties"] as! [String: Any]
        XCTAssertEqual(props["$lib"] as? String, "photox")
        XCTAssertEqual(props["$lib_version"] as? String, "0.267.0")
        XCTAssertEqual(props["$os"] as? String, "macOS")
        XCTAssertEqual(props["$os_version"] as? String, "15.4")
        XCTAssertEqual(props["app_opens"] as? Int, 142)
        XCTAssertEqual(props["photos_seen"] as? Int, 9831)
        XCTAssertEqual(props["shoots_opened"] as? Int, 12)
        XCTAssertEqual(props["exports_completed"] as? Int, 4)
        XCTAssertEqual(props["images_exported"] as? Int, 87)
        XCTAssertEqual(props["scores_set"] as? Int, 2103)
        XCTAssertEqual(props["first_launch_at"] as? String, "2026-05-23T07:00:00Z")
    }

    // MARK: - distinct_id stability

    func test_distinctID_isStableAcrossFlushes() async throws {
        StubURLProtocol.responseStatus = 200
        let store = makeStore()
        let uploader = TelemetryUploader(
            apiKey: "phc_x",
            session: makeStubbedSession(),
            defaults: store
        )

        _ = await uploader.flush(counters: .zero, firstLaunchAt: Date(),
                                 appVersion: "1", osVersion: "1")
        _ = await uploader.flush(counters: .zero, firstLaunchAt: Date(),
                                 appVersion: "1", osVersion: "1")
        XCTAssertEqual(StubURLProtocol.capturedBodies.count, 2)

        let id1 = try Self.distinctID(from: StubURLProtocol.capturedBodies[0])
        let id2 = try Self.distinctID(from: StubURLProtocol.capturedBodies[1])
        XCTAssertEqual(id1, id2, "distinct_id must persist across flushes")
        // And the same value should be readable from the store.
        XCTAssertEqual(store.string(forKey: SettingsKey.telemetryAnonymousID), id1)
    }

    // MARK: - absolute-totals semantics

    func test_flush_sendsAbsoluteTotals_notDeltas() async throws {
        StubURLProtocol.responseStatus = 200
        let uploader = TelemetryUploader(
            apiKey: "phc_x",
            session: makeStubbedSession(),
            defaults: makeStore()
        )

        let c1 = UsageMetrics.Counters(appOpens: 1)
        let c2 = UsageMetrics.Counters(appOpens: 2)
        let c3 = UsageMetrics.Counters(appOpens: 5)
        for c in [c1, c2, c3] {
            _ = await uploader.flush(counters: c, firstLaunchAt: Date(),
                                     appVersion: "1", osVersion: "1")
        }
        XCTAssertEqual(StubURLProtocol.capturedBodies.count, 3)
        let opens = try StubURLProtocol.capturedBodies.map {
            try Self.props(from: $0)["app_opens"] as? Int ?? -1
        }
        XCTAssertEqual(opens, [1, 2, 5],
                       "each flush should carry the absolute total, not the delta")
    }

    // MARK: - network failure

    func test_flush_networkError_returnsFailure() async {
        StubURLProtocol.responseError = NSError(domain: NSURLErrorDomain,
                                                code: NSURLErrorTimedOut)
        let uploader = TelemetryUploader(
            apiKey: "phc_x",
            session: makeStubbedSession(),
            defaults: makeStore()
        )
        let result = await uploader.flush(
            counters: .zero, firstLaunchAt: Date(),
            appVersion: "1", osVersion: "1"
        )
        XCTAssertFalse(result.success)
        XCTAssertNotNil(result.error)
    }

    // MARK: - helpers

    private static func distinctID(from body: Data) throws -> String {
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        return obj["distinct_id"] as! String
    }
    private static func props(from body: Data) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        return obj["properties"] as! [String: Any]
    }
}

// MARK: - URLProtocol stub

/// Captures every URLRequest sent through a session configured with
/// this protocol class; replies with the caller-set `responseStatus`
/// (or `responseError` if set). Resets between tests via `setUp`.
private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []
    nonisolated(unsafe) static var capturedBodies: [Data] = []
    nonisolated(unsafe) static var responseStatus: Int = 200
    nonisolated(unsafe) static var responseError: Error?

    static func reset() {
        capturedRequests.removeAll()
        capturedBodies.removeAll()
        responseStatus = 200
        responseError = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequests.append(request)
        // URLProtocol strips the body off of URLRequest before
        // canInit is called; recover it from the bodyStream when
        // URLSession converts the request for transport.
        if let body = request.httpBody {
            Self.capturedBodies.append(body)
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: 4096)
                if read <= 0 { break }
                data.append(buf, count: read)
            }
            Self.capturedBodies.append(data)
        } else {
            Self.capturedBodies.append(Data())
        }

        if let error = Self.responseError {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.responseStatus,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
