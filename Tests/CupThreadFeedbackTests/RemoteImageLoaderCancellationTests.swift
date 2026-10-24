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

/// One-shot gate the mock download thread blocks on, so a download stays
/// in flight until the test releases it. Fixed handler sleeps made the
/// cancellation tests flaky: under full-suite load a 30 ms caller-side
/// sleep can overshoot a 200 ms download window, and the cancellation then
/// lands on an already-completed download (cache warmed, in-flight entry
/// already cleaned up) instead of a mid-flight one.
private final class DownloadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false

    /// Blocks the calling (handler) thread until `open()` or the timeout,
    /// returning whether the gate was opened.
    func hold(upTo timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if !isOpen {
            condition.wait(until: Date().addingTimeInterval(timeout))
        }
        return isOpen
    }

    /// Releases every waiting handler thread; idempotent.
    func open() {
        condition.lock()
        isOpen = true
        condition.signal()
        condition.unlock()
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

    /// Installs a handler whose download stays in flight (blocked on `gate`)
    /// until the test opens it, so cancellation always lands mid-download no
    /// matter how far the scheduler delays the test's own execution.
    private func setGatedHandler(
        counter: CancellationRequestCounter,
        gate: DownloadGate,
        path: String,
        png: Data
    ) {
        let imageURL = makeImageURL(path)
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            counter.record()
            gate.hold(upTo: 5)
            return (self.makeImageResponse(request.url ?? imageURL), png)
        }
    }

    /// Waits until the load for `url` has registered its in-flight entry so a
    /// following `cancel()` deterministically hits a running download.
    private func waitUntilInFlight(
        _ loader: RemoteImageLoader,
        url: URL,
        timeout: TimeInterval = 2
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if loader.inFlightCount == 1 { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return loader.inFlightCount == 1
    }

    @Test func callerCancellationStillWarmsCacheWhenUnderlyingDownloadSucceeds() async throws {
        let counter = CancellationRequestCounter()
        let gate = DownloadGate()
        defer { gate.open() }
        let png = makePNGData()
        let imageURL = makeImageURL("/caller-cancelled.png")
        setGatedHandler(counter: counter, gate: gate, path: "/caller-cancelled.png", png: png)
        let loader = RemoteImageLoader(session: makeMockSession())

        let callerTask = Task { @MainActor in
            try await loader.image(for: imageURL)
        }

        try #require(await waitUntilInFlight(loader, url: imageURL), "load never became in-flight")
        callerTask.cancel()

        let result = await callerTask.result
        switch result {
        case .success:
            Issue.record("Expected caller task to be cancelled")
        case .failure(let error):
            #expect(error.isSdkCancellation, "The caller task must surface SDK cancellation")
        }
        gate.open()

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
        let gate = DownloadGate()
        defer { gate.open() }
        let png = makePNGData()
        let imageURL = makeImageURL("/concurrent-cancellation.png")
        setGatedHandler(counter: counter, gate: gate, path: "/concurrent-cancellation.png", png: png)
        let loader = RemoteImageLoader(session: makeMockSession())

        let firstCaller = Task { @MainActor in
            try await loader.image(for: imageURL)
        }

        try #require(await waitUntilInFlight(loader, url: imageURL), "load never became in-flight")

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
        gate.open()

        let secondImage = try await secondCaller.value
        #expect(RemoteImageLoader.decodedPixelDimensions(of: secondImage).width > 0)
        #expect(counter.requestCount == 1, "Both callers must share a single download")
        #expect(loader.cachedImageIfPresent(for: imageURL) != nil)
    }

    @Test func callerCancellationDoesNotPrematurelyClearInFlightEntry() async throws {
        let counter = CancellationRequestCounter()
        let gate = DownloadGate()
        defer { gate.open() }
        let png = makePNGData()
        let imageURL = makeImageURL("/coalesce-after-cancellation.png")
        setGatedHandler(counter: counter, gate: gate, path: "/coalesce-after-cancellation.png", png: png)
        let loader = RemoteImageLoader(session: makeMockSession())

        let caller1 = Task { @MainActor in
            try await loader.image(for: imageURL)
        }

        try #require(await waitUntilInFlight(loader, url: imageURL), "load never became in-flight")
        caller1.cancel()

        _ = await caller1.result

        #expect(loader.inFlightCount == 1, "In-flight task must not be cleared while background download is active")
        gate.open()

        let caller2Image = try await loader.image(for: imageURL)
        #expect(RemoteImageLoader.decodedPixelDimensions(of: caller2Image).width > 0)
        #expect(counter.requestCount == 1, "Caller 2 must coalesce onto the running download instead of starting a new one")
    }

    @Test func callerCancellationDoesNotPoisonNegativeCache() async throws {
        let counter = CancellationRequestCounter()
        let gate = DownloadGate()
        defer { gate.open() }
        let png = makePNGData()
        let imageURL = makeImageURL("/no-negative-cache-poisoning.png")
        setGatedHandler(counter: counter, gate: gate, path: "/no-negative-cache-poisoning.png", png: png)
        let loader = RemoteImageLoader(session: makeMockSession())

        let caller = Task { @MainActor in
            try await loader.image(for: imageURL)
        }

        try #require(await waitUntilInFlight(loader, url: imageURL), "load never became in-flight")
        caller.cancel()
        _ = await caller.result

        #expect(loader.recentFailureCount == 0, "Caller cancellation must never be recorded in recentFailures")
        gate.open()

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

    // MARK: CachedRemoteImage phase mapping (issue #421)

    /// Issue #421: a cancelled image load is not a failure. `CachedRemoteImage`
    /// must keep its current phase when SwiftUI tears `.task(id:)` down
    /// (scroll-away, cell recycling, view dismissal) instead of flashing the
    /// failure placeholder — the detached download keeps running and may still
    /// land in the cache for the next appearance.
    @Test func cancellationThrownByTaskJoinDoesNotMapToFailurePhase() {
        // `awaitJoinedTask` resumes its cancelled caller with a bare
        // CancellationError; URLSession surfaces the same interruption as
        // URLError(.cancelled). Neither may map to the failure phase.
        #expect(!RemoteImagePhase.mapsToFailurePhase(CancellationError()))
        #expect(!RemoteImagePhase.mapsToFailurePhase(URLError(.cancelled)))
    }

    @Test func cancelledImageLoadErrorDoesNotMapToFailurePhase() async throws {
        let counter = CancellationRequestCounter()
        let gate = DownloadGate()
        defer { gate.open() }
        let png = makePNGData()
        let imageURL = makeImageURL("/phase-cancelled.png")
        setGatedHandler(counter: counter, gate: gate, path: "/phase-cancelled.png", png: png)
        let loader = RemoteImageLoader(session: makeMockSession())

        let caller = Task { @MainActor in
            try await loader.image(for: imageURL)
        }
        try #require(await waitUntilInFlight(loader, url: imageURL), "load never became in-flight")
        caller.cancel()

        guard case .failure(let error) = await caller.result else {
            Issue.record("Expected the cancelled caller to throw")
            return
        }
        #expect(error.isSdkCancellation)
        #expect(
            !RemoteImagePhase.mapsToFailurePhase(error),
            "The error thrown by a cancelled image(for:) call must not transition CachedRemoteImage to .failure"
        )
    }

    @Test func genuineNetworkFailureStillMapsToFailurePhase() async throws {
        let imageURL = makeImageURL("/phase-genuine-failure.png")
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            (self.makeImageResponse(request.url ?? imageURL, status: 500), Data())
        }
        let loader = RemoteImageLoader(session: makeMockSession())

        do {
            _ = try await loader.image(for: imageURL)
            Issue.record("Expected the failed download to throw")
        } catch {
            #expect(RemoteImagePhase.mapsToFailurePhase(error), "A genuine download failure must map to .failure")
        }
    }

    @Test func genuineErrorInCancelledCallerTaskDoesNotMapToFailurePhase() async {
        // SwiftUI may cancel the .task before its body observes the teardown;
        // once the caller task is cancelled the phase must stay put even if a
        // genuine-looking error surfaces in the same window.
        let caller = Task { @MainActor in
            while !Task.isCancelled {
                await Task.yield()
            }
            return RemoteImagePhase.mapsToFailurePhase(URLError(.timedOut))
        }
        caller.cancel()
        #expect(await caller.value == false, "A cancelled caller task must not transition to .failure even on a genuine error")
    }
}
