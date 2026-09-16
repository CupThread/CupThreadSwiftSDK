import Foundation
import Testing
@testable import CupThreadFeedback

/// Lock-guarded request counter for the image mock host.
private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    @discardableResult
    func record() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

@Suite(.serialized)
@MainActor
struct RemoteImageLoaderTests {
    private static let host = "image.test.example.com"

    // 2×2 red PNG, generated once and verified decodable on every platform.
    private static let pngBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7gP9i18U1AAAAABJRU5ErkJggg=="

    private func makePNGData() -> Data {
        Data(base64Encoded: Self.pngBase64)!
    }

    private func makeImageURL(_ path: String) -> URL {
        URL(string: "https://\(Self.host)\(path)")!
    }

    private func makeImageResponse(_ url: URL, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
        )!
    }

    @Test func secondSequentialLoadResolvesFromCacheWithSingleNetworkHit() async throws {
        let counter = RequestCounter()
        let png = makePNGData()
        let imageURL = makeImageURL("/avatar.png")
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            counter.record()
            return (self.makeImageResponse(request.url ?? imageURL), png)
        }
        let loader = RemoteImageLoader(session: makeMockSession())

        let first = try await loader.image(for: imageURL)
        let second = try await loader.image(for: imageURL)

        #expect(counter.requestCount == 1)
        #expect(first === second)
    }

    @Test func concurrentLoadsForSameURLAreCoalescedIntoSingleDownload() async throws {
        let counter = RequestCounter()
        let png = makePNGData()
        let imageURL = makeImageURL("/coalesced.png")
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            counter.record()
            // Hold the first request open so the second caller joins the
            // in-flight task instead of starting a new download.
            Thread.sleep(forTimeInterval: 0.2)
            return (self.makeImageResponse(request.url ?? imageURL), png)
        }
        let loader = RemoteImageLoader(session: makeMockSession())

        async let first = loader.image(for: imageURL)
        async let second = loader.image(for: imageURL)
        let (firstImage, secondImage) = try await (first, second)

        #expect(counter.requestCount == 1)
        #expect(firstImage === secondImage)
    }

    @Test func failedDownloadIsNotCachedAndNextLoadRetries() async throws {
        let counter = RequestCounter()
        let png = makePNGData()
        let imageURL = makeImageURL("/flaky.png")
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            let call = counter.record()
            if call == 1 {
                return (self.makeImageResponse(request.url ?? imageURL, status: 500), Data())
            }
            return (self.makeImageResponse(request.url ?? imageURL), png)
        }
        let loader = RemoteImageLoader(session: makeMockSession())

        await #expect(throws: (any Error).self) {
            try await loader.image(for: imageURL)
        }
        #expect(counter.requestCount == 1)

        let recovered = try await loader.image(for: imageURL)
        #expect(counter.requestCount == 2)
    }

    @Test func cachedImageIdentityIsPreservedAcrossLoads() async throws {
        let counter = RequestCounter()
        let png = makePNGData()
        let imageURL = makeImageURL("/identity.png")
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            counter.record()
            return (self.makeImageResponse(request.url ?? imageURL), png)
        }
        let loader = RemoteImageLoader(session: makeMockSession())

        _ = try await loader.image(for: imageURL)
        let fromCache = try await loader.image(for: imageURL)
        let stillCached = try await loader.image(for: imageURL)

        #expect(counter.requestCount == 1)
        #expect(fromCache === stillCached)
    }

    @Test func distinctURLsAreCachedIndependently() async throws {
        let counter = RequestCounter()
        let png = makePNGData()
        let firstURL = makeImageURL("/one.png")
        let secondURL = makeImageURL("/two.png")
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            counter.record()
            return (self.makeImageResponse(request.url ?? firstURL), png)
        }
        let loader = RemoteImageLoader(session: makeMockSession())

        _ = try await loader.image(for: firstURL)
        _ = try await loader.image(for: secondURL)
        _ = try await loader.image(for: firstURL)
        _ = try await loader.image(for: secondURL)

        #expect(counter.requestCount == 2)
    }
}
