import Foundation

/// One canned mock response: status code, body, and any headers beyond the
/// JSON content type every mock reply carries.
private struct MockResponse {
    let statusCode: Int
    let body: Data
    let extraHeaders: [String: String]

    init(_ statusCode: Int, _ body: Data, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.body = body
        self.extraHeaders = headers
    }
}

/// URLProtocol subclass that mocks all CupThread API requests for Demo and UI tests.
final class DemoMockURLProtocol: URLProtocol, @unchecked Sendable {

    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        // Intercept requests to cupthread domains or any mock requests
        return url.host?.contains("cupthread") == true
            || url.host?.contains("localhost") == true
            || url.host?.contains("127.0.0.1") == true
    }

    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let path = url.path
        let query = url.query ?? ""
        let body = Self.requestBody(from: request)

        let mockResponse = Self.response(
            for: path,
            query: query,
            method: request.httpMethod ?? "GET",
            body: body
        )

        let response = HTTPURLResponse(
            url: url,
            statusCode: mockResponse.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": "*"
            ].merging(mockResponse.extraHeaders) { _, extra in extra }
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: mockResponse.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    // MARK: - Request-economy probe

    /// Counts the config GETs served this process so the UI tests can pin the
    /// shared-client contract: a launch (and any later foregrounding) must
    /// cost exactly one `GET /api/v1/public/config/{appKey}` per TTL window,
    /// not one per surface or per re-created client. `URLProtocol` loads on
    /// background queues, so the counter is lock-guarded.
    private static let counterLock = NSLock()
    private static var _configRequestCount = 0

    static var configRequestCount: Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        return _configRequestCount
    }

    private static func recordConfigRequest() {
        counterLock.lock()
        _configRequestCount += 1
        counterLock.unlock()
    }

    private static func response(
        for path: String,
        query: String,
        method: String,
        body: Data?
    ) -> MockResponse {
        if path.contains("/api/v1/public/config/") {
            recordConfigRequest()
            return MockResponse(200, DemoMockData.appConfigJSON)
        }
        if path.contains("/api/v1/public/columns/") {
            return MockResponse(200, DemoMockData.columnsJSON)
        }
        if path.contains("/api/v1/public/versions/") {
            return MockResponse(200, DemoMockData.versionsJSON)
        }
        if path.contains("/api/v1/feature-requests") {
            return handleFeatureRequests(path: path, query: query, method: method, body: body)
        }
        if path.contains("/api/v1/public/apps/") {
            return handleAppsPublic(path: path)
        }
        if path.contains("/api/v1/uploads/sessions") {
            if let rejection = turnstileRejectionIfUngated(body: body, code: "turnstile_verification_failed") {
                return rejection
            }
            return MockResponse(201, DemoMockData.uploadSessionJSON)
        }
        if path.contains("/api/v1/uploads/") {
            return MockResponse(200, DemoMockData.uploadedFileJSON)
        }
        if path.contains("/api/v1/feedback") {
            if let rejection = turnstileRejectionIfUngated(body: body, code: "turnstile_required") {
                return rejection
            }
            return MockResponse(200, DemoMockData.submitFeedbackJSON)
        }
        return MockResponse(200, Data("{}".utf8))
    }

    private static func handleFeatureRequests(
        path: String,
        query: String,
        method: String,
        body: Data?
    ) -> MockResponse {
        if path.contains("/vote") {
            return MockResponse(200, DemoMockData.voteJSON)
        }
        if method == "POST" {
            if let rejection = turnstileRejectionIfUngated(body: body, code: "turnstile_required") {
                return rejection
            }
            return MockResponse(201, DemoMockData.submitFeatureRequestJSON)
        }
        return MockResponse(200, DemoMockData.allFeatureRequestsJSON)
    }

    private static func handleAppsPublic(path: String) -> MockResponse {
        if path.contains("/changelog/subscribe") {
            return MockResponse(200, DemoMockData.subscribeJSON)
        }
        if path.contains("/changelog/unsubscribe") {
            return MockResponse(200, DemoMockData.unsubscribeJSON)
        }
        if path.contains("/changelog") {
            return MockResponse(200, DemoMockData.changelogJSON)
        }
        if path.contains("/user") {
            return MockResponse(200, DemoMockData.userAttributesJSON)
        }
        return MockResponse(200, Data("{}".utf8))
    }

    // MARK: - Turnstile gate emulation (issue #53)

    /// Emulates the production human-verification gate on the three intake
    /// routes (`POST /api/v1/feedback`, `POST /api/v1/feature-requests`,
    /// `POST /api/v1/uploads/sessions`) so the demo and the UI tests exercise
    /// the same contract production enforces: token-less intake is rejected
    /// with a Turnstile-shaped 403, and submissions presenting a token
    /// succeed. Off by default — every existing mock-mode flow keeps its
    /// unconditionally successful fixtures.
    static var emulatesTurnstileGate: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("-emulateTurnstileGate")
            || processInfo.environment["DEMO_EMULATE_TURNSTILE_GATE"] == "1"
    }

    /// The production-shaped 403 when the gate is emulated and the intake
    /// body carries no presentable Turnstile token; `nil` lets the request
    /// through to the success fixtures.
    private static func turnstileRejectionIfUngated(body: Data?, code: String) -> MockResponse? {
        guard emulatesTurnstileGate, turnstileToken(in: body) == nil else { return nil }
        return MockResponse(
            403,
            DemoMockData.turnstileGateRejectionJSON(code: code),
            headers: ["X-Request-Id": "req_turnstile_mock_gated"]
        )
    }

    /// Extracts the `turnstileToken` body field the SDK's intake payloads
    /// send, treating missing, non-string, and whitespace-only values as
    /// token-less.
    private static func turnstileToken(in body: Data?) -> String? {
        guard let body,
              let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let token = payload["turnstileToken"] as? String else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Reads a request body through `httpBodyStream` — URLSession hands
    /// `httpBody` data to URLProtocol subclasses as a stream, so the direct
    /// property is usually `nil` here.
    private static func requestBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        let bufferSize = 16 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        var data = Data()
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
