import Foundation
import Testing
@testable import CupThreadFeedback

// Caller-cancellation contract of `AppConfigStore` (CONC-1): the fetch task is
// self-finalizing, so a caller cancelled while waiting can neither drop the
// completed response nor strand its co-waiters.
//
// All tests share the static MockURLProtocol handler, so they run serialized.
// This suite uses its own base host so it can run in parallel with the other
// suites.
@Suite("AppConfigStore cancellation", .serialized)
@MainActor
struct AppConfigStoreCancellationTests {
    private static let host = "appconfig-cancel.example.com"

    private let suiteName: String
    private let defaults: UserDefaults

    init() {
        suiteName = "AppConfigStoreCancellationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    // MARK: - Helpers

    /// Thread-safe request counter installed in the mock handler.
    private final class RequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var configRequests = 0

        func record(path: String) {
            lock.lock()
            defer { lock.unlock() }
            if path.contains("/public/config/") {
                configRequests += 1
            }
        }
    }

    private func makeStore(appKey: String) -> AppConfigStore {
        AppConfigStore(
            lastGood: SdkConfigCache(
                appKey: appKey,
                storage: UserDefaultsConfigStorage(userDefaults: defaults)
            )
        )
    }

    /// Installs a handler that signals `started` when the request reaches it,
    /// then parks until `gate` is signalled before answering — so a test can
    /// hold the fetch in flight and cancel its caller mid-request.
    private func setGatedConfigHandler(
        appKey: String,
        counter: RequestCounter,
        started: DispatchSemaphore,
        gate: DispatchSemaphore,
        status: Int = 200
    ) throws {
        let payload: Data
        switch status {
        case 200: payload = try configJSON(appKey: appKey)
        default: payload = Data("server unavailable".utf8)
        }
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            counter.record(path: request.url?.path ?? "")
            started.signal()
            // Park until the test releases the fetch. Runs on a URLSession
            // queue, so the blocking wait does not hold the main actor. The
            // budget is generous: on a loaded CI runner the test-side
            // handshake can be starved for tens of seconds by the CPU-bound
            // image-decode suites running in parallel, and the park expiring
            // early would complete the fetch before the caller is cancelled,
            // voiding the test's premise.
            _ = gate.wait(timeout: .now() + 30)
            return (makeHTTPResponse(status: status), payload)
        }
    }

    private func configJSON(appKey: String) throws -> Data {
        var payload = makeConfigJSON()
        payload["appKey"] = appKey
        return try encodeJSON(payload)
    }

    /// Awaits a semaphore without blocking the enclosing actor: the blocking
    /// wait runs on a background thread via a synchronous seam
    /// (`DispatchSemaphore.wait` is unavailable in async contexts, even
    /// inside a detached task's closure). Bounded so a broken handshake fails
    /// instead of stalling the run — but generously: on a loaded CI runner
    /// the request can be starved for tens of seconds by the CPU-bound
    /// parallel suites before it reaches the mock handler, and a tight budget
    /// here fails the handshake even though nothing is broken.
    private func awaitSignal(_ semaphore: DispatchSemaphore, what: String) async throws {
        let result = await Task.detached(priority: .userInitiated) {
            Self.blockingWait(semaphore)
        }.value
        #expect(result == .success, "Timed out waiting for \(what)")
    }

    private nonisolated static func blockingWait(
        _ semaphore: DispatchSemaphore
    ) -> DispatchTimeoutResult {
        semaphore.wait(timeout: .now() + 30)
    }

    /// Starts a cached read and suspends until its request is genuinely in
    /// flight (parked inside the mock handler), so the returned task can be
    /// cancelled mid-fetch.
    private func startCancellableRead(
        client: FeedbackClient,
        started: DispatchSemaphore
    ) async throws -> Task<PublicAppConfig, Error> {
        let caller = Task { try await client.cachedAppConfig() }
        try await awaitSignal(started, what: "the config request to reach the mock handler")
        return caller
    }

    // MARK: - Tests

    @Test func callerCancellationStillWarmsCacheWhenUnderlyingFetchSucceeds() async throws {
        let appKey = "app_cancel_warm"
        let counter = RequestCounter()
        let started = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        try setGatedConfigHandler(
            appKey: appKey, counter: counter, started: started, gate: gate
        )
        let store = makeStore(appKey: appKey)
        let client = makeClient(
            baseURL: URL(string: "https://\(Self.host)")!,
            appKey: appKey,
            configStore: store
        )

        let caller = try await startCancellableRead(client: client, started: started)
        caller.cancel()

        gate.signal()  // Let the underlying fetch complete successfully.
        _ = await caller.result

        #expect(
            store.cachedConfig() != nil,
            "A fetch that completed after its creator was cancelled must still warm the TTL cache"
        )
        #expect(
            store.lastGoodAppearance() != nil,
            "A fetch that completed after its creator was cancelled must persist the last-good appearance"
        )

        // The next read within the TTL window must reuse the warmed cache
        // instead of issuing a duplicate request for the dropped response.
        let next = try await client.cachedAppConfig()
        #expect(counter.configRequests == 1, "A warmed cache must not trigger a duplicate fetch")
        #expect(next.appKey == appKey)
    }

    @Test func cancelledCreatorDoesNotStrandCoWaiters() async throws {
        let appKey = "app_cancel_cowaiter"
        let counter = RequestCounter()
        let started = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        try setGatedConfigHandler(
            appKey: appKey, counter: counter, started: started, gate: gate
        )
        let store = makeStore(appKey: appKey)
        let client = makeClient(
            baseURL: URL(string: "https://\(Self.host)")!,
            appKey: appKey,
            configStore: store
        )

        let creator = try await startCancellableRead(client: client, started: started)
        creator.cancel()

        // A co-waiter joins while the original fetch is still parked in
        // flight; it must not be stranded by the creator's cancellation.
        let coWaiter = Task { try await client.cachedAppConfig() }

        gate.signal()
        let config = try await coWaiter.value
        _ = await creator.result

        #expect(config.appKey == appKey)
        #expect(counter.configRequests == 1, "The co-waiter must share the original in-flight request")
        #expect(store.cachedConfig() != nil, "The shared fetch must warm the cache for later readers")
    }

    @Test func failedFetchAfterCreatorCancellationReleasesSlotForRetry() async throws {
        let appKey = "app_cancel_failure"
        let counter = RequestCounter()
        let started = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        try setGatedConfigHandler(
            appKey: appKey, counter: counter, started: started, gate: gate, status: 500
        )
        let store = makeStore(appKey: appKey)
        let client = makeClient(
            baseURL: URL(string: "https://\(Self.host)")!,
            appKey: appKey,
            configStore: store
        )

        let caller = try await startCancellableRead(client: client, started: started)
        caller.cancel()

        gate.signal()  // The underlying fetch now completes with a 500.
        _ = await caller.result

        // The failed fetch must leave the slot released: the next read either
        // joins the in-flight failure (and surfaces it) or starts fresh.
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            counter.record(path: request.url?.path ?? "")
            return (makeHTTPResponse(), try configJSON(appKey: appKey))
        }
        do {
            _ = try await client.cachedAppConfig()
        } catch {
            // Joined the in-flight failure; the retry below must succeed.
        }
        let recovered = try await client.cachedAppConfig()
        #expect(counter.configRequests == 2, "The failed fetch must free the slot for exactly one retry")
        #expect(recovered.appKey == appKey)
        #expect(store.cachedConfig() != nil)
    }
}
