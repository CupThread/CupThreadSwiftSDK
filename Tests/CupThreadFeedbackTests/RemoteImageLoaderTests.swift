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

/// Lock-guarded, manually advanced clock for driving the negative-cache window.
private final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ current: Date = Date(timeIntervalSinceReferenceDate: 0)) {
        self.current = current
    }

    var time: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
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

    @Test func permanentlyFailingURLHitsNetworkOnceInsideRetryWindow() async throws {
        let counter = RequestCounter()
        let imageURL = makeImageURL("/always-404.png")
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            counter.record()
            return (self.makeImageResponse(request.url ?? imageURL, status: 404), Data())
        }
        let loader = RemoteImageLoader(session: makeMockSession())

        for _ in 0..<3 {
            do {
                _ = try await loader.image(for: imageURL)
                Issue.record("Expected the failed fetch to throw")
            } catch let urlError as URLError {
                #expect(urlError.code == .badServerResponse, "Replays must surface the recorded error")
            } catch {
                Issue.record("Expected URLError, got \(error)")
            }
        }

        #expect(counter.requestCount == 1, "Failures inside the retry window must replay without network requests")
        #expect(loader.recentFailureCount == 1)
    }

    @Test func failureWindowExpiryResumesNetworkRetries() async throws {
        let clock = SteppingClock()
        let counter = RequestCounter()
        let imageURL = makeImageURL("/expiring-404.png")
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            counter.record()
            return (self.makeImageResponse(request.url ?? imageURL, status: 404), Data())
        }
        let loader = RemoteImageLoader(
            session: makeMockSession(),
            failureRetryInterval: 60,
            now: { clock.time }
        )

        await #expect(throws: (any Error).self) {
            try await loader.image(for: imageURL)
        }
        #expect(counter.requestCount == 1)

        clock.advance(by: 61)

        await #expect(throws: (any Error).self) {
            try await loader.image(for: imageURL)
        }
        #expect(counter.requestCount == 2, "A lapsed negative-cache entry must allow a new network request")
    }

    @Test func transientFailureRecoversAfterRetryWindowAndSuccessIsCached() async throws {
        let clock = SteppingClock()
        let counter = RequestCounter()
        let png = makePNGData()
        let imageURL = makeImageURL("/flaky-then-fine.png")
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            let call = counter.record()
            if call == 1 {
                return (self.makeImageResponse(request.url ?? imageURL, status: 500), Data())
            }
            return (self.makeImageResponse(request.url ?? imageURL), png)
        }
        let loader = RemoteImageLoader(
            session: makeMockSession(),
            failureRetryInterval: 60,
            now: { clock.time }
        )

        await #expect(throws: (any Error).self) {
            try await loader.image(for: imageURL)
        }
        #expect(counter.requestCount == 1)

        clock.advance(by: 61)
        let recovered = try await loader.image(for: imageURL)
        #expect(counter.requestCount == 2)
        #expect(loader.recentFailureCount == 0, "A successful fetch must clear the negative-cache entry")

        let fromCache = try await loader.image(for: imageURL)
        #expect(counter.requestCount == 2, "Success caching must be unchanged by the failure ledger")
        #expect(recovered === fromCache)
    }

    @Test func expiredFailureLedgerEntriesArePrunedOnInsert() async throws {
        let clock = SteppingClock()
        let counter = RequestCounter()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            counter.record()
            let fallback = URL(string: "https://\(Self.host)/prune-fallback.png")!
            return (self.makeImageResponse(request.url ?? fallback, status: 404), Data())
        }
        let loader = RemoteImageLoader(
            session: makeMockSession(),
            failureRetryInterval: 60,
            now: { clock.time }
        )

        for index in 0..<8 {
            await #expect(throws: (any Error).self) {
                try await loader.image(for: makeImageURL("/prune-\(index).png"))
            }
        }
        #expect(loader.recentFailureCount == 8)

        clock.advance(by: 61)
        await #expect(throws: (any Error).self) {
            try await loader.image(for: makeImageURL("/prune-fresh.png"))
        }

        #expect(loader.recentFailureCount == 1, "Expired ledger entries must be pruned so the ledger stays bounded")
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

    @Test func disallowedSchemeThrowsBadURLWithoutHittingNetwork() async throws {
        let counter = RequestCounter()
        MockURLProtocol.setHandler(forHost: Self.host) { _ in
            counter.record()
            return (self.makeImageResponse(self.makeImageURL("/fallback.png")), self.makePNGData())
        }
        let loader = RemoteImageLoader(session: makeMockSession())

        let disallowedURLStrings = [
            "http://insecure.example.com/avatar.png",
            "http://localhost:3000/avatar.png",
            "file:///etc/passwd",
            "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY44YAAAAASUVORK5CYII=",
            "javascript:alert(1)",
            "myapp://custom-scheme/image.png",
            "tel:1234567890"
        ]

        for string in disallowedURLStrings {
            let url = try #require(URL(string: string))
            do {
                _ = try await loader.image(for: url)
                Issue.record("Expected URLError(.badURL) for \(string)")
            } catch let urlError as URLError {
                #expect(urlError.code == .badURL)
            } catch {
                Issue.record("Expected URLError, got \(error)")
            }
        }

        #expect(counter.requestCount == 0, "Disallowed schemes must never trigger network requests")
    }

    @Test func validHttpsAvatarLoadProceedsAndHitsNetwork() async throws {
        let counter = RequestCounter()
        let png = makePNGData()
        let imageURL = makeImageURL("/avatar-happy-path.png")
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            counter.record()
            return (self.makeImageResponse(request.url ?? imageURL), png)
        }
        let loader = RemoteImageLoader(session: makeMockSession())

        _ = try await loader.image(for: imageURL)
        #expect(counter.requestCount == 1)
    }
}
