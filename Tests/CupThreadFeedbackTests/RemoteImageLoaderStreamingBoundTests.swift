import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Streaming transfer bound (PERF-7)

/// URLProtocol that streams its payload in fixed-size chunks with a small
/// delay, so tests can observe a mid-transfer cancellation. The loader builds
/// its delegate-backed session from this protocol's configuration.
///
/// Each started transfer owns its counters, so a late `stopLoading` from a
/// previous test's invalidated session cannot mark the next test's transfer
/// as cancelled.
private final class StreamingImageURLProtocol: URLProtocol, @unchecked Sendable {
    private final class TransferState: @unchecked Sendable {
        let lock = NSLock()
        let payload: Data
        let chunkSize: Int
        let status: Int
        let headers: [String: String]
        var deliveredBytes = 0
        var stopped = false

        init(payload: Data, chunkSize: Int, status: Int, headers: [String: String]) {
            self.payload = payload
            self.chunkSize = chunkSize
            self.status = status
            self.headers = headers
        }

        /// The next chunk, or `nil` once the client cancelled or the payload
        /// is exhausted; delivered bytes are recorded as the chunk is
        /// produced.
        func takeChunk(at offset: Int) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            guard !stopped, offset < payload.count else { return nil }
            let end = min(offset + chunkSize, payload.count)
            let chunk = payload.subdata(in: offset..<end)
            deliveredBytes += chunk.count
            return chunk
        }

        func markStopped() {
            lock.lock()
            stopped = true
            lock.unlock()
        }

        var deliveredSnapshot: Int {
            lock.lock()
            defer { lock.unlock() }
            return deliveredBytes
        }

        var stoppedSnapshot: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }
    }

    private static let configurationLock = NSLock()
    nonisolated(unsafe) private static var configuredState = TransferState(
        payload: Data(),
        chunkSize: 1,
        status: 200,
        headers: [:]
    )
    private var transferState: TransferState?

    static func configure(
        payload: Data,
        chunkSize: Int,
        status: Int = 200,
        headers: [String: String] = ["Content-Type": "image/png"]
    ) {
        configurationLock.lock()
        configuredState = TransferState(
            payload: payload,
            chunkSize: max(1, chunkSize),
            status: status,
            headers: headers
        )
        configurationLock.unlock()
    }

    private static var currentState: TransferState {
        configurationLock.lock()
        defer { configurationLock.unlock() }
        return configuredState
    }

    static var deliveredBytesSnapshot: Int { currentState.deliveredSnapshot }

    static var stoppedSnapshot: Bool { currentState.stoppedSnapshot }

    // URLProtocol requires class-func overrides; `static` would not dispatch
    // through the ObjC runtime. swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let state = Self.currentState
        transferState = state
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: state.status,
            httpVersion: nil,
            headerFields: state.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            var offset = 0
            while let chunk = state.takeChunk(at: offset) {
                self.client?.urlProtocol(self, didLoad: chunk)
                offset += chunk.count
                Thread.sleep(forTimeInterval: 0.0005)
            }
            if !state.stoppedSnapshot {
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {
        transferState?.markStopped()
    }
}

@Suite(.serialized)
@MainActor
struct RemoteImageLoaderStreamingBoundTests {
    private static let host = "image-streaming.test.example.com"

    // 2×2 red PNG, the same fixture the loader suites use.
    private static let pngBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7gP9i18U1AAAAABJRU5ErkJggg=="

    private func makeImageURL(_ path: String) -> URL {
        URL(string: "https://\(Self.host)\(path)")!
    }

    private func makeStreamingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingImageURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func oversizedStreamingBodyCancelsTheTransferAtTheCap() async throws {
        let payload = Data(repeating: 0x41, count: 16 * 1_024 * 1_024)
        StreamingImageURLProtocol.configure(payload: payload, chunkSize: 1_024)
        let url = makeImageURL("/oversized-stream.png")
        let cap = 16 * 1_024
        let loader = RemoteImageLoader(session: makeStreamingSession(), maxResponseBytes: cap)

        do {
            _ = try await loader.image(for: url)
            Issue.record("Expected the streamed body to be rejected at the cap")
        } catch let error as URLError {
            #expect(error.code == .cannotDecodeContentData)
        } catch {
            Issue.record("Expected URLError, got \(error)")
        }

        // The loader's buffer is the memory contract under test: it must never
        // hold more than the cap, independent of how far the mock raced ahead.
        #expect(
            loader.peakBufferedBodyBytes <= cap,
            "The loader buffered \(loader.peakBufferedBodyBytes) bytes over a \(cap)-byte cap"
        )

        // Cancellation propagates to the protocol through URLSession's
        // queues; give it a bounded window to be observed.
        var waited = 0
        while !StreamingImageURLProtocol.stoppedSnapshot && waited < 50 {
            try await Task.sleep(for: .milliseconds(40))
            waited += 1
        }
        let delivered = StreamingImageURLProtocol.deliveredBytesSnapshot
        #expect(StreamingImageURLProtocol.stoppedSnapshot, "The loader must cancel the task at the cap")
        #expect(
            delivered < payload.count,
            "The full body must not be delivered before the transfer is cancelled"
        )
        #expect(loader.cachedImageIfPresent(for: url) == nil, "A rejected body must never be cached")
        #expect(loader.recentFailureCount == 1, "The rejection must replay through the negative cache")

        await #expect(throws: (any Error).self) {
            try await loader.image(for: url)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(
            StreamingImageURLProtocol.deliveredBytesSnapshot == delivered,
            "The negative-cache replay must not restart the transfer"
        )
    }

    @Test func bodyAtTheCapIsAcceptedAndDecoded() async throws {
        let png = try #require(Data(base64Encoded: Self.pngBase64))
        StreamingImageURLProtocol.configure(payload: png, chunkSize: 7)
        let loader = RemoteImageLoader(session: makeStreamingSession(), maxResponseBytes: png.count)

        let image = try await loader.image(for: makeImageURL("/at-cap.png"))
        let dimensions = RemoteImageLoader.decodedPixelDimensions(of: image)

        #expect(dimensions.width == 2)
        #expect(dimensions.height == 2)
    }

    @Test func bodyOneByteOverTheCapIsRejected() async throws {
        let png = try #require(Data(base64Encoded: Self.pngBase64))
        StreamingImageURLProtocol.configure(payload: png + Data([0]), chunkSize: 8)
        let url = makeImageURL("/one-byte-over.png")
        let loader = RemoteImageLoader(session: makeStreamingSession(), maxResponseBytes: png.count)

        do {
            _ = try await loader.image(for: url)
            Issue.record("Expected the one-byte-over body to be rejected")
        } catch let error as URLError {
            #expect(error.code == .cannotDecodeContentData)
        } catch {
            Issue.record("Expected URLError, got \(error)")
        }

        #expect(loader.cachedImageIfPresent(for: url) == nil)
    }

    /// URLProtocol bypasses URLSession's content decoder, so this cannot
    /// observe an actual gzip expansion. It pins the rule the production path
    /// relies on: the cap is applied to the bytes the transport delivers —
    /// which URLSession has already decompressed — and a compressed response
    /// cannot postpone the check until the whole body arrives.
    @Test func contentEncodingHeaderDoesNotBypassTheStreamingCap() async throws {
        let payload = Data(repeating: 0x41, count: 8 * 1_024 * 1_024)
        StreamingImageURLProtocol.configure(
            payload: payload,
            chunkSize: 1_024,
            headers: ["Content-Type": "image/png", "Content-Encoding": "gzip"]
        )
        let url = makeImageURL("/compressed-body.png")
        let cap = 16 * 1_024
        let loader = RemoteImageLoader(session: makeStreamingSession(), maxResponseBytes: cap)

        do {
            _ = try await loader.image(for: url)
            Issue.record("Expected the compressed body to be rejected at the cap")
        } catch let error as URLError {
            #expect(error.code == .cannotDecodeContentData)
        } catch {
            Issue.record("Expected URLError, got \(error)")
        }

        #expect(
            loader.peakBufferedBodyBytes <= cap,
            "A Content-Encoding header must not let the buffer grow past the cap"
        )
        try await Task.sleep(for: .milliseconds(100))
        #expect(
            StreamingImageURLProtocol.deliveredBytesSnapshot < payload.count,
            "A Content-Encoding header must not delay the cap until the body is buffered"
        )
    }
}
