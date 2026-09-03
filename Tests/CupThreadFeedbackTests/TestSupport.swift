import Foundation
@testable import CupThreadFeedback

// MARK: - Shared test helpers

/// URLProtocol subclass that intercepts all requests and routes them to a per-host handler.
///
/// Suites marked `.serialized` only serialize their own tests, so two suites can run in
/// parallel. Keying handlers by request host (each suite uses its own base URL) keeps
/// parallel suites from stomping each other's handlers.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let defaultHost = "test.example.com"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    /// Handler for requests to the default mock host (https://test.example.com).
    nonisolated(unsafe) static var requestHandler: Handler? {
        get { handler(forHost: defaultHost) }
        set { setHandler(forHost: defaultHost, newValue) }
    }

    static func setHandler(forHost host: String, _ handler: Handler?) {
        lock.lock()
        defer { lock.unlock() }
        handlers[host] = handler
    }

    private static func handler(forHost host: String) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[host]
    }

    // URLProtocol requires class-func overrides; `static` would not dispatch
    // through the ObjC runtime. swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler(forHost: request.url?.host ?? "") else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Thread-safe box for capturing Sendable values from URLProtocol handler closures.
final class CaptureBox<T: Sendable>: @unchecked Sendable {
    var value: T?
}

/// Create a URLSession backed by MockURLProtocol.
func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

/// Create a FeedbackClient wired to the mock session.
func makeClient(
    baseURL: URL = URL(string: "https://test.example.com")!,
    appKey: String = "app_testkey123456",
    platform: FeedbackPlatform = .ios
) -> FeedbackClient {
    let config = FeedbackClientConfiguration(baseURL: baseURL, appKey: appKey, defaultPlatform: platform)
    return FeedbackClient(configuration: config, session: makeMockSession())
}

/// Make an HTTPURLResponse.
func makeHTTPResponse(status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "https://test.example.com")!,
        statusCode: status,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )!
}

/// Encode a dictionary to Data.
func encodeJSON(_ dict: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: dict)
}

/// Read httpBody from an intercepted request (handles both body and stream).
func bodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    var data = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
    defer { buffer.deallocate() }
    stream.open()
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: 4096)
        guard read > 0 else { break }
        data.append(buffer, count: read)
    }
    stream.close()
    return data
}

/// Parse captured Data as a [String: Any] dictionary.
func parseJSONDict(_ data: Data) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

/// Make default config JSON dictionary for tests.
func makeConfigJSON() -> [String: Any] {
    [
        "appId": "app-1",
        "appKey": "app_testkey123456",
        "slug": "demo-app",
        "name": "Demo App",
        "storeUrl": NSNull(),
        "storeKind": NSNull(),
        "iconUrl": "https://example.com/icon.png",
        "allowPublic": true,
        "allowedPlatforms": ["ios", "macos"],
        "maxAttachmentBytes": 20_000_000,
        "allowAnonymousRoadmap": true,
        "allowAnonymousVote": false,
        "allowAnonymousFeedback": true
    ]
}
