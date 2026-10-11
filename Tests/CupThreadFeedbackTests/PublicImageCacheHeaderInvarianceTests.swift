import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Public Image Cache-Header Invariance Tests (Issue #394)

/// URLProtocol stub that records intercepted requests so tests can count
/// network hits through an injected loader session.
private final class CacheRecordingURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

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

/// Thread-safe request counter handed to the stub's handler.
private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func record(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return urls.count
    }
}

/// Pins that the public image pipeline's caching is invariant to the
/// `Cache-Control` header the endpoint serves (issue #394: SaaS PR #775
/// dropped `immutable` from `Cache-Control: public, max-age=86400`).
///
/// The loader must keep caching fetched images under the new header exactly
/// as it did under the legacy one — if header-sensitive caching ever creeps
/// into the loader (e.g. only caching `immutable` responses, which would
/// re-download every avatar on scroll), these pins turn red.
///
/// Note on scope: only the loader-owned layer is pinned here. The transport
/// cache layer is Foundation's, not the SDK's — the SDK sets no
/// `cachePolicy` or `urlCache` anywhere (intake clients run on
/// `FeedbackClient.defaultSession`, image fetches on the injected session) —
/// and endpoint `Cache-Control` semantics are not observable through a
/// custom-`URLProtocol` session on current Apple OSes: Foundation stores
/// URLProtocol responses unconditionally per the protocol's storage-policy
/// flag (even `no-store`) and never consults the cache for subsequent
/// requests over such sessions (verified across ephemeral/default
/// configurations, custom and shared `URLCache`, and both
/// `.useProtocolCachePolicy` and `.returnCacheDataElseLoad`). Freshness
/// reuse therefore cannot be pinned without a loopback HTTP server and is
/// owned by the real HTTP stack.
@Suite("PublicImageCacheHeaderInvariance", .serialized)
struct PublicImageCacheHeaderInvarianceTests {
    // Valid 16x16 WebP image fixture (same bytes as PublicImageDeliveryTests).
    private static let webpFixtureBase64 =
        "UklGRjoAAABXRUJQVlA4IC4AAACQAQCdASoQABAAAUAmJaACdLoAA5gA/vtV4/+lwf/S4P/pcH/pcH8bss4bpAAA"

    /// Serves `bytes` with a production-shaped 200 (image content type, ETag,
    /// and the given Cache-Control) for every request to `host`, recording
    /// each intercepted request in `recorder`.
    private func serveImage(
        host: String,
        url: URL,
        recorder: RequestRecorder,
        cacheControl: String,
        bytes: Data
    ) {
        CacheRecordingURLProtocol.setHandler(forHost: host) { request in
            if let requestURL = request.url {
                recorder.record(requestURL)
            }
            let response = HTTPURLResponse(
                url: request.url ?? url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "image/webp",
                    "ETag": "\"\(host)\"",
                    "Cache-Control": cacheControl
                ]
            )!
            return (response, bytes)
        }
    }

    /// Two sequential loader fetches of one URL under `cacheControl` must hit
    /// the network exactly once; the repeat resolves from the loader's
    /// decoded-image cache as the same instance.
    @MainActor
    private func assertLoaderCachesUnderHeader(cacheControl: String) async throws {
        let host = "loader-pin-\(UUID().uuidString).cupthread.com"
        let url = URL(string: "https://\(host)/api/v1/files/images%2Favatar.png")!
        let recorder = RequestRecorder()
        serveImage(
            host: host,
            url: url,
            recorder: recorder,
            cacheControl: cacheControl,
            bytes: Data(base64Encoded: Self.webpFixtureBase64)!
        )
        defer { CacheRecordingURLProtocol.setHandler(forHost: host, nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CacheRecordingURLProtocol.self]
        let loader = RemoteImageLoader(session: URLSession(configuration: configuration))

        let first = try await loader.image(for: url)
        let second = try await loader.image(for: url)

        #expect(recorder.count == 1, "Repeat load must resolve from the loader cache without a second fetch")
        #expect(second === first)
    }

    @Test func loaderCachesUnderProductionHeaderWithoutImmutable() async throws {
        // New header: `immutable` dropped (SaaS PR #775).
        try await assertLoaderCachesUnderHeader(cacheControl: "public, max-age=86400")
    }

    @Test func loaderCachesUnderLegacyImmutableHeaderIdentically() async throws {
        // Legacy header: `immutable` present (pre-SaaS-PR-#775). Caching must
        // not depend on the dropped directive.
        try await assertLoaderCachesUnderHeader(cacheControl: "public, max-age=86400, immutable")
    }
}
