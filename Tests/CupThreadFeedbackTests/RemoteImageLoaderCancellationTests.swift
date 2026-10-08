import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
@testable import CupThreadFeedback

/// Lock-guarded request counter for the cancellation mock host.
private final class CancellationRequestCounter: @unchecked Sendable {
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
struct RemoteImageLoaderCancellationTests {
    private static let host = "image-cancellation.test.example.com"

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

    @Test func callerCancellationStillWarmsCacheWhenUnderlyingDownloadSucceeds() async throws {
        let counter = CancellationRequestCounter()
        let png = makePNGData()
        let imageURL = makeImageURL("/caller-cancelled.png")
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            counter.record()
            Thread.sleep(forTimeInterval: 0.15)
            return (self.makeImageResponse(request.url ?? imageURL), png)
        }
        let loader = RemoteImageLoader(session: makeMockSession())

        let callerTask = Task { @MainActor in
            try await loader.image(for: imageURL)
        }

        try await Task.sleep(for: .milliseconds(30))
        callerTask.cancel()

        let result = await callerTask.result
        switch result {
        case .success:
            Issue.record("Expected caller task to be cancelled")
        case .failure(let error):
            #expect(error.isSdkCancellation, "The caller task must surface SDK cancellation")
        }

        var pollCount = 0
        while loader.cachedImageIfPresent(for: imageURL) == nil && pollCount < 50 {
            try await Task.sleep(for: .milliseconds(20))
            pollCount += 1
        }

        #expect(loader.cachedImageIfPresent(for: imageURL) != nil, "Cache must be warmed despite caller cancellation")
        #expect(loader.inFlightCount == 0, "In-flight tracking must be cleaned up")

        let cachedImage = try await loader.image(for: imageURL)
        #expect(RemoteImageLoader.decodedPixelDimensions(of: cachedImage).width > 0)
        #expect(counter.requestCount == 1, "Cached image must not hit the network a second time")
    }

    @Test func concurrentSubscriberReceivesImageEvenIfFirstCallerCancels() async throws {
        let counter = CancellationRequestCounter()
        let png = makePNGData()
        let imageURL = makeImageURL("/concurrent-cancellation.png")
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            counter.record()
            Thread.sleep(forTimeInterval: 0.15)
            return (self.makeImageResponse(request.url ?? imageURL), png)
        }
        let loader = RemoteImageLoader(session: makeMockSession())

        let firstCaller = Task { @MainActor in
            try await loader.image(for: imageURL)
        }

        try await Task.sleep(for: .milliseconds(30))

        let secondCaller = Task { @MainActor in
            try await loader.image(for: imageURL)
        }

        firstCaller.cancel()

        let firstResult = await firstCaller.result
        switch firstResult {
        case .success:
            Issue.record("First caller should have been cancelled")
        case .failure(let error):
            #expect(error.isSdkCancellation)
        }

        let secondImage = try await secondCaller.value
        #expect(RemoteImageLoader.decodedPixelDimensions(of: secondImage).width > 0)
        #expect(counter.requestCount == 1, "Both callers must share a single download")
        #expect(loader.cachedImageIfPresent(for: imageURL) != nil)
    }

    @Test func callerCancellationDoesNotPrematurelyClearInFlightEntry() async throws {
        let counter = CancellationRequestCounter()
        let png = makePNGData()
        let imageURL = makeImageURL("/coalesce-after-cancellation.png")
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            counter.record()
            Thread.sleep(forTimeInterval: 0.2)
            return (self.makeImageResponse(request.url ?? imageURL), png)
        }
        let loader = RemoteImageLoader(session: makeMockSession())

        let caller1 = Task { @MainActor in
            try await loader.image(for: imageURL)
        }

        try await Task.sleep(for: .milliseconds(30))
        caller1.cancel()

        _ = await caller1.result

        #expect(loader.inFlightCount == 1, "In-flight task must not be cleared while background download is active")

        let caller2Image = try await loader.image(for: imageURL)
        #expect(RemoteImageLoader.decodedPixelDimensions(of: caller2Image).width > 0)
        #expect(counter.requestCount == 1, "Caller 2 must coalesce onto the running download instead of starting a new one")
    }

    @Test func callerCancellationDoesNotPoisonNegativeCache() async throws {
        let counter = CancellationRequestCounter()
        let png = makePNGData()
        let imageURL = makeImageURL("/no-negative-cache-poisoning.png")
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            counter.record()
            Thread.sleep(forTimeInterval: 0.1)
            return (self.makeImageResponse(request.url ?? imageURL), png)
        }
        let loader = RemoteImageLoader(session: makeMockSession())

        let caller = Task { @MainActor in
            try await loader.image(for: imageURL)
        }

        try await Task.sleep(for: .milliseconds(20))
        caller.cancel()
        _ = await caller.result

        #expect(loader.recentFailureCount == 0, "Caller cancellation must never be recorded in recentFailures")

        var pollCount = 0
        while loader.cachedImageIfPresent(for: imageURL) == nil && pollCount < 50 {
            try await Task.sleep(for: .milliseconds(20))
            pollCount += 1
        }

        #expect(loader.recentFailureCount == 0, "Completed successful fetch must have zero recent failures")
        let loaded = try await loader.image(for: imageURL)
        #expect(RemoteImageLoader.decodedPixelDimensions(of: loaded).width > 0)
    }

    @Test func underlyingNetworkFailureIsRecordedInNegativeCacheAndClearsInFlight() async throws {
        let counter = CancellationRequestCounter()
        let imageURL = makeImageURL("/actual-failure.png")
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            counter.record()
            return (self.makeImageResponse(request.url ?? imageURL, status: 500), Data())
        }
        let loader = RemoteImageLoader(session: makeMockSession())

        await #expect(throws: (any Error).self) {
            try await loader.image(for: imageURL)
        }

        #expect(loader.inFlightCount == 0, "In-flight task must be cleared on network failure")
        #expect(loader.recentFailureCount == 1, "Actual network failure must be recorded in recentFailures")

        await #expect(throws: (any Error).self) {
            try await loader.image(for: imageURL)
        }
        #expect(counter.requestCount == 1, "Negative cache must replay error without contacting the network")
    }
}
