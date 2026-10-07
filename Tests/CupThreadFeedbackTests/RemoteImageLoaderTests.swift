import Foundation
import ImageIO
import Testing
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
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

    /// Solid-color PNG of the given pixel size, synthesized in-test so decode
    /// bounds can be exercised against arbitrarily large sources.
    private func makePNGData(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
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

    // MARK: PERF-3: bounded decode and byte-budgeted cache

    @Test func largeAvatarSourceDecodesBoundedToDefaultPixelEdge() async throws {
        let largePNG = makePNGData(width: 3000, height: 3000)
        let imageURL = makeImageURL("/huge-avatar.png")
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            return (self.makeImageResponse(request.url ?? imageURL), largePNG)
        }
        let loader = RemoteImageLoader(session: makeMockSession())

        let image = try await loader.image(for: imageURL)
        let pixels = RemoteImageLoader.decodedPixelDimensions(of: image)

        #expect(pixels.width > 0, "A decodable source must produce a non-empty bitmap")
        #expect(
            max(pixels.width, pixels.height) <= Int(RemoteImageLoader.defaultMaxDecodedPixelEdge),
            "A 3000×3000 source must decode bounded to the pixel-edge cap, not at full resolution"
        )
    }

    @Test func decodePixelEdgeCapIsInjectable() async throws {
        let png = makePNGData(width: 300, height: 200)
        let imageURL = makeImageURL("/injectable-edge.png")
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            return (self.makeImageResponse(request.url ?? imageURL), png)
        }
        let loader = RemoteImageLoader(session: makeMockSession(), maxDecodedPixelEdge: 64)

        let image = try await loader.image(for: imageURL)
        let pixels = RemoteImageLoader.decodedPixelDimensions(of: image)

        #expect(max(pixels.width, pixels.height) <= 64, "The injected pixel-edge cap must bound the decode")
    }

    @Test func smallSourceImagesAreNotUpscaled() async throws {
        let png = makePNGData()
        let imageURL = makeImageURL("/tiny-avatar.png")
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            return (self.makeImageResponse(request.url ?? imageURL), png)
        }
        let loader = RemoteImageLoader(session: makeMockSession())

        let image = try await loader.image(for: imageURL)
        let pixels = RemoteImageLoader.decodedPixelDimensions(of: image)

        #expect(pixels.width == 2 && pixels.height == 2, "Sources under the cap must keep their native size")
    }

    @Test func oversizedResponseBodyIsRejectedAndNotCached() async throws {
        let counter = RequestCounter()
        let png = makePNGData()
        let imageURL = makeImageURL("/oversized-body.png")
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            counter.record()
            return (self.makeImageResponse(request.url ?? imageURL), png)
        }
        // The 2×2 PNG fixture is a valid image well above this cap.
        let loader = RemoteImageLoader(session: makeMockSession(), maxResponseBytes: 32)

        do {
            _ = try await loader.image(for: imageURL)
            Issue.record("Expected the oversized body to be rejected")
        } catch let urlError as URLError {
            #expect(urlError.code == .cannotDecodeContentData, "Oversized bodies must surface a decode failure")
        } catch {
            Issue.record("Expected URLError, got \(error)")
        }

        #expect(loader.cachedImageIfPresent(for: imageURL) == nil, "A rejected body must never be cached")
        #expect(loader.recentFailureCount == 1, "The rejection must replay through the negative cache")

        await #expect(throws: (any Error).self) {
            try await loader.image(for: imageURL)
        }
        #expect(counter.requestCount == 1, "The rejection must replay offline inside the retry window")
    }

    @Test func cacheEvictsByByteCostBeforeCountLimit() async throws {
        let counter = RequestCounter()
        let png = makePNGData()
        let urls = (0..<4).map { makeImageURL("/cost-\($0).png") }
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            counter.record()
            return (self.makeImageResponse(request.url ?? urls[0]), png)
        }
        // Learn the fixture's per-entry cost offline, then size the byte
        // budget to hold at most two entries while the count limit (100)
        // stays far above the four URLs loaded.
        let fixture = try RemoteImageLoader.decodeBoundedImage(from: png, maxPixelEdge: 600)
        let fixtureCost = RemoteImageLoader.cacheCost(of: fixture)
        #expect(fixtureCost > 0, "Every decodable image must carry a non-zero cache cost")

        let loader = RemoteImageLoader(
            session: makeMockSession(),
            cacheCountLimit: 100,
            cacheCostLimit: 2 * fixtureCost
        )
        for url in urls {
            _ = try await loader.image(for: url)
        }
        #expect(counter.requestCount == 4)

        let stillCached = urls.filter { loader.cachedImageIfPresent(for: $0) != nil }
        #expect(
            stillCached.count <= 2,
            "Entries must be evicted by accumulated cost (budget \(2 * fixtureCost)) while the count limit (100) cannot bind"
        )
    }

    @Test func cacheCostReflectsDecodedBitmapBytes() throws {
        // 10×10 RGBA8 bitmap with a deliberately padded 64-byte row stride:
        // the cost must follow bytesPerRow (640), not width × height × 4 (400).
        let context = CGContext(
            data: nil,
            width: 10,
            height: 10,
            bitsPerComponent: 8,
            bytesPerRow: 64,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        let cgImage = context.makeImage()!
        #expect(cgImage.bytesPerRow == 64, "The fixture must preserve its padded row stride")
        #if canImport(UIKit)
        let image = UIImage(cgImage: cgImage)
        #elseif canImport(AppKit)
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif

        #expect(RemoteImageLoader.cacheCost(of: image) == 640)
    }
}
