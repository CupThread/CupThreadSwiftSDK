import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("SearchRequestThrottle")
struct SearchRequestThrottleTests {
    /// Deterministic virtual clock: `now` reads `instant`, and the throttle's
    /// injected sleep jumps straight to the deadline instead of wall-time
    /// waiting, so production-scale windows (60 s) resolve instantly.
    private final class VirtualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant: ContinuousClock.Instant
        let base: ContinuousClock.Instant

        init() {
            base = ContinuousClock().now
            instant = base
        }

        var value: ContinuousClock.Instant {
            get { lock.lock(); defer { lock.unlock() }; return instant }
            set { lock.lock(); defer { lock.unlock() }; instant = newValue }
        }

        /// Milliseconds elapsed since `base`.
        var elapsedMilliseconds: Int64 {
            let duration = value - base
            let seconds = Double(duration.components.seconds)
            let attoseconds = Double(duration.components.attoseconds)
            return Int64((seconds + attoseconds / 1e18) * 1_000)
        }

        func advance(by duration: Duration) {
            value += duration
        }
    }

    private func makeThrottle(
        minimumInterval: Duration = .seconds(1.5),
        windowPeriod: Duration = .seconds(60),
        windowCapacity: Int = 28,
        cooldownDuration: Duration = .seconds(60)
    ) -> (throttle: SearchRequestThrottle, clock: VirtualClock) {
        let clock = VirtualClock()
        let throttle = SearchRequestThrottle(
            minimumInterval: minimumInterval,
            windowPeriod: windowPeriod,
            windowCapacity: windowCapacity,
            cooldownDuration: cooldownDuration,
            now: { clock.value },
            sleepUntil: { deadline in
                if Task.isCancelled { throw CancellationError() }
                clock.value = deadline
            }
        )
        return (throttle, clock)
    }

    @Test func firstQueryAdmitsImmediately() async {
        let (throttle, clock) = makeThrottle()
        let admitted = await throttle.waitForAdmission(key: "features|swift|")
        #expect(admitted)
        #expect(clock.elapsedMilliseconds == 0)
    }

    @Test func duplicateQueryIsSkippedWithoutNetworkCall() async {
        let (throttle, clock) = makeThrottle()
        #expect(await throttle.waitForAdmission(key: "features|swift|"))
        #expect(await throttle.waitForAdmission(key: "features|swift|") == false)
        #expect(clock.elapsedMilliseconds == 0, "duplicate check must not sleep")
    }

    @Test func versionFilterChangeCountsAsNewQuery() async {
        let (throttle, _) = makeThrottle()
        #expect(await throttle.waitForAdmission(key: "features|swift|"))
        #expect(await throttle.waitForAdmission(key: "features|swift|v1"))
    }

    @Test func consecutiveQueriesAreSpacedApart() async {
        let (throttle, clock) = makeThrottle()
        var grantOffsets: [Int64] = []
        for index in 0..<5 {
            let admitted = await throttle.waitForAdmission(key: "features|query-\(index)|")
            #expect(admitted)
            grantOffsets.append(clock.elapsedMilliseconds)
        }
        #expect(grantOffsets == [0, 1500, 3000, 4500, 6000])
    }

    @Test func simulatedKeystrokeStreamStaysUnderServerBudget() async {
        let (throttle, clock) = makeThrottle()
        var grantOffsets: [Int64] = []
        for index in 0..<40 {
            let admitted = await throttle.waitForAdmission(key: "features|keystroke-\(index)|")
            #expect(admitted)
            grantOffsets.append(clock.elapsedMilliseconds)
        }
        // At least 1.5 s spacing between consecutive query-bearing fetches.
        for (previous, current) in zip(grantOffsets, grantOffsets.dropFirst()) {
            #expect(current - previous >= 1_500)
        }
        // At most 28 admitted fetches (windowCapacity, below the server's 30)
        // in any 60 s sliding window. Half-open interval: a grant exactly one
        // window period after the window start has aged out of it.
        for (index, start) in grantOffsets.enumerated() {
            let windowCount = grantOffsets.filter { $0 >= start && $0 < start + 60_000 }.count
            #expect(windowCount <= 28, "window starting at grant \(index) admitted \(windowCount)")
        }
    }

    @Test func cooldownSuppressesEmissionsAndResumesAfterExpiry() async {
        let (throttle, clock) = makeThrottle()
        #expect(await throttle.waitForAdmission(key: "features|before|"))
        await throttle.enterCooldown()
        #expect(await throttle.waitForAdmission(key: "features|during|") == false)
        #expect(clock.elapsedMilliseconds == 0, "cooldown denial must not sleep")
        clock.advance(by: .seconds(61))
        #expect(await throttle.waitForAdmission(key: "features|during|"))
    }

    @Test func cooldownClearsDuplicateGate() async {
        let (throttle, clock) = makeThrottle()
        #expect(await throttle.waitForAdmission(key: "features|same|"))
        await throttle.enterCooldown()
        clock.advance(by: .seconds(61))
        // The query that hit 429 never rendered results, so the first
        // emission after the cooldown must fetch even for the same key.
        #expect(await throttle.waitForAdmission(key: "features|same|"))
    }

    @Test func cancelledWaitRecordsNoReservation() async {
        let clock = VirtualClock()
        let throttle = SearchRequestThrottle(
            now: { clock.value },
            // Always "cancelled mid-wait": the spacing sleep throws before
            // any admission is recorded.
            sleepUntil: { _ in throw CancellationError() }
        )
        #expect(await throttle.waitForAdmission(key: "k1"), "first admission needs no wait")
        #expect(await throttle.waitForAdmission(key: "k2") == false, "cancelled spacing wait skips the fetch")
        // The failed wait must have committed nothing: once spacing is
        // satisfied, `k2` admits without waiting — had the cancelled wait
        // recorded a reservation, this would trip duplicate suppression.
        clock.advance(by: .seconds(2))
        #expect(await throttle.waitForAdmission(key: "k2"))
    }

    @Test func windowExhaustionWaitsForOldestSlotToFree() async {
        let (throttle, clock) = makeThrottle(minimumInterval: .zero, windowCapacity: 3)
        for index in 0..<3 {
            #expect(await throttle.waitForAdmission(key: "k\(index)"))
        }
        #expect(clock.elapsedMilliseconds == 0)
        // Window full: the next admission waits until the oldest slot frees.
        #expect(await throttle.waitForAdmission(key: "k3"))
        #expect(clock.elapsedMilliseconds == 60_000)
    }
}

@Suite("SearchReloadOutcome")
struct SearchReloadOutcomeTests {
    @Test func rateLimitedUsesFriendlySearchMessage() {
        let error = FeedbackClientError.rateLimited(message: "Too many searches. Please try again shortly.")
        let friendly = CupThreadStrings.tr("cupthread.search.rate_limited")
        #expect(SearchReloadOutcome.outcome(for: error, hasExistingContent: true) == .inlineNotice(friendly))
        #expect(SearchReloadOutcome.outcome(for: error, hasExistingContent: false) == .fullScreenError(friendly))
    }

    @Test func otherErrorsKeepTheirLocalizedMessage() {
        let error = FeedbackClientError.unexpectedStatus(code: 500, message: "boom", requestId: nil)
        #expect(
            SearchReloadOutcome.outcome(for: error, hasExistingContent: true) == .inlineNotice(error.localizedDescription)
        )
        #expect(
            SearchReloadOutcome.outcome(for: error, hasExistingContent: false) == .fullScreenError(error.localizedDescription)
        )
    }

    /// #31: a cancelled reload never reached a verdict — with or without
    /// rendered content, the outcome must direct the caller to leave the
    /// surface's state untouched instead of showing an error.
    @Test func cancellationIsSuppressedRegardlessOfExistingContent() {
        #expect(SearchReloadOutcome.outcome(for: CancellationError(), hasExistingContent: true) == nil)
        #expect(SearchReloadOutcome.outcome(for: CancellationError(), hasExistingContent: false) == nil)
        #expect(SearchReloadOutcome.outcome(for: URLError(.cancelled), hasExistingContent: true) == nil)
        #expect(SearchReloadOutcome.outcome(for: URLError(.cancelled), hasExistingContent: false) == nil)
    }

    /// Only cancellation is suppressed — genuine transport failures still
    /// follow the inline-notice / full-screen policy.
    @Test func networkFailureIsNeverSuppressed() {
        let error = URLError(.notConnectedToInternet)
        let message = FriendlyError.message(for: error)
        #expect(SearchReloadOutcome.outcome(for: error, hasExistingContent: true) == .inlineNotice(message))
        #expect(SearchReloadOutcome.outcome(for: error, hasExistingContent: false) == .fullScreenError(message))
    }
}
