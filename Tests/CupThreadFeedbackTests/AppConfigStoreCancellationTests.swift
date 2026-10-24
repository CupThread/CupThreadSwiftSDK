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

    // MARK: - Handshake (issue #564)

    /// Handshake between the mock URL handler (a synchronous closure running
    /// on a URLSession queue) and the test task, with no wall-clock budgets.
    /// The `DispatchSemaphore` pair this suite used before failed
    /// `.timedOut` assertions once a loaded CI runner starved the fixed 30 s
    /// handshake past its budget, and tuning the budget could only move the
    /// cliff: the starvation source (parallel CPU-bound suites) is unbounded.
    ///
    /// - The test side polls `isSignaled` from `awaitSignal(_:what:)`, so the
    ///   handshake suspends instead of parking a thread and runner load can
    ///   delay it arbitrarily without ever failing it.
    /// - The handler side parks budget-free: expiring early would complete
    ///   the fetch before the caller is cancelled and void the test's
    ///   premise. Every test signals the gate before it awaits the fetch's
    ///   result, so the park always ends.
    private final class SignalGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var signaled = false

        var isSignaled: Bool {
            condition.lock()
            defer { condition.unlock() }
            return signaled
        }

        /// Block the calling (URLSession queue) thread until `signal()`.
        /// Runs off the main actor, so the blocking wait never stalls the
        /// enclosing test task.
        func park() {
            condition.lock()
            while !signaled { condition.wait() }
            condition.unlock()
        }

        /// Release the parked handler; idempotent.
        func signal() {
            condition.lock()
            signaled = true
            condition.broadcast()
            condition.unlock()
        }
    }

    /// Thrown when the `awaitSignal` hang-guard expires: the mock handler
    /// never fired at all, which is a broken test premise — not runner load,
    /// and not a product failure.
    private struct HandshakeTimeoutError: Error, CustomStringConvertible {
        let what: String
        var description: String {
            "timed out waiting for \(what); the mock handler never fired"
        }
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

    /// Builds a client whose session tolerates a long-parked request: the
    /// budget-free handshake holds the fetch in flight for as long as the
    /// test task stays starved, and the default 60 s request timeout would
    /// fail it mid-test with a product-looking error (issue #564).
    private func makeGatedClient(appKey: String, configStore: AppConfigStore) -> FeedbackClient {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        sessionConfiguration.timeoutIntervalForRequest = 600
        return FeedbackClient(
            configuration: FeedbackClientConfiguration(
                baseURL: URL(string: "https://\(Self.host)")!,
                appKey: appKey
            ),
            session: URLSession(configuration: sessionConfiguration),
            configStore: configStore
        )
    }

    /// Installs a handler that signals `started` when the request reaches it,
    /// then parks until `gate` is signalled before answering — so a test can
    /// hold the fetch in flight and cancel its caller mid-request.
    private func setGatedConfigHandler(
        appKey: String,
        counter: RequestCounter,
        started: SignalGate,
        gate: SignalGate,
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
            // queue, so the blocking wait does not hold the main actor, and
            // it is budget-free (issue #564): the park cannot expire early
            // and complete the fetch before the caller is cancelled, which
            // would void the test's premise. Every test signals the gate
            // before it awaits the fetch's result, so the park always ends.
            gate.park()
            return (makeHTTPResponse(status: status), payload)
        }
    }

    private func configJSON(appKey: String) throws -> Data {
        var payload = makeConfigJSON()
        payload["appKey"] = appKey
        return try encodeJSON(payload)
    }

    /// Waits for the mock handler to report the request in flight.
    ///
    /// The handshake suspends between polls, so a loaded CI runner can delay
    /// it arbitrarily without failing the test (issue #564) — there is no
    /// `.timedOut` assertion left to trip. The deadline below is a hang-guard
    /// only: it bounds a genuinely broken handshake with a descriptive error
    /// instead of stalling the job, and sits far above the tens-of-seconds
    /// starvation CI runners have actually produced (issue #562).
    private func awaitSignal(_ gate: SignalGate, what: String) async throws {
        let deadline = ContinuousClock.now + .seconds(600)
        while !gate.isSignaled {
            if ContinuousClock.now >= deadline {
                Issue.record("Handshake hung: \(HandshakeTimeoutError(what: what))")
                throw HandshakeTimeoutError(what: what)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Starts a cached read and suspends until its request is genuinely in
    /// flight (parked inside the mock handler), so the returned task can be
    /// cancelled mid-fetch.
    private func startCancellableRead(
        client: FeedbackClient,
        started: SignalGate
    ) async throws -> Task<PublicAppConfig, Error> {
        let caller = Task { try await client.cachedAppConfig() }
        try await awaitSignal(started, what: "the config request to reach the mock handler")
        return caller
    }

    // MARK: - Tests

    @Test func callerCancellationStillWarmsCacheWhenUnderlyingFetchSucceeds() async throws {
        let appKey = "app_cancel_warm"
        let counter = RequestCounter()
        let started = SignalGate()
        let gate = SignalGate()
        try setGatedConfigHandler(
            appKey: appKey, counter: counter, started: started, gate: gate
        )
        let store = makeStore(appKey: appKey)
        let client = makeGatedClient(appKey: appKey, configStore: store)

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
        let started = SignalGate()
        let gate = SignalGate()
        try setGatedConfigHandler(
            appKey: appKey, counter: counter, started: started, gate: gate
        )
        let store = makeStore(appKey: appKey)
        let client = makeGatedClient(appKey: appKey, configStore: store)

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
        let started = SignalGate()
        let gate = SignalGate()
        try setGatedConfigHandler(
            appKey: appKey, counter: counter, started: started, gate: gate, status: 500
        )
        let store = makeStore(appKey: appKey)
        let client = makeGatedClient(appKey: appKey, configStore: store)

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
