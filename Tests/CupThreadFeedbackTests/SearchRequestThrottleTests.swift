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

    @Test func clearingQueryResetsDuplicateGateForSubsequentSearches() async {
        let (throttle, clock) = makeThrottle()

        // Initial search
        #expect(await throttle.waitForAdmission(key: "features|swift|"))

        // Immediate duplicate is correctly suppressed
        #expect(await throttle.waitForAdmission(key: "features|swift|") == false)

        // User clears search bar and loads plain listing
        await throttle.resetLastAdmittedKey()

        // Advance virtual clock past minimum interval
        clock.advance(by: .seconds(2))

        // User re-enters "swift" -> must be admitted
        #expect(await throttle.waitForAdmission(key: "features|swift|"))
    }

    @Test func resetLastAdmittedKeyStillRespectsMinimumInterval() async {
        let (throttle, clock) = makeThrottle()

        #expect(await throttle.waitForAdmission(key: "features|swift|"))

        // Reset the duplicate gate immediately
        await throttle.resetLastAdmittedKey()

        // Admitting the same key again immediately must wait for minimumInterval (1.5 s)
        let admitted = await throttle.waitForAdmission(key: "features|swift|")
        #expect(admitted)
        #expect(clock.elapsedMilliseconds == 1500)
    }

    @Test func resetLastAdmittedKeyDuringCooldownDoesNotBypassCooldown() async {
        let (throttle, clock) = makeThrottle()

        #expect(await throttle.waitForAdmission(key: "features|before|"))
        await throttle.enterCooldown()

        // Resetting last admitted key during an active cooldown must not bypass the 429 block
        await throttle.resetLastAdmittedKey()
        #expect(await throttle.waitForAdmission(key: "features|before|") == false)

        // After cooldown expires, the query admits
        clock.advance(by: .seconds(61))
        #expect(await throttle.waitForAdmission(key: "features|before|"))
    }

    @Test func recordingCountsAgainstTheWindow() async {
        let (throttle, clock) = makeThrottle(minimumInterval: .zero, windowCapacity: 28)
        for index in 0..<26 {
            #expect(await throttle.waitForAdmission(key: "typed-\(index)"))
        }
        await throttle.recordQueryFetch()
        await throttle.recordQueryFetch()
        #expect(clock.elapsedMilliseconds == 0)
        #expect(await throttle.admittedCount == 28)

        // 29th admission must wait until the oldest admission leaves the 60 s window
        #expect(await throttle.waitForAdmission(key: "typed-26"))
        #expect(clock.elapsedMilliseconds == 60_000)
    }

    @Test func recordingNeverDelaysTheRecorder() async {
        let (throttle, clock) = makeThrottle(minimumInterval: .zero, windowCapacity: 3)
        // Overfill capacity using recordQueryFetch
        for index in 0..<10 {
            await throttle.recordQueryFetch(key: "fetch-\(index)")
        }
        #expect(clock.elapsedMilliseconds == 0, "recording must never delay or suspend the caller")
        #expect(await throttle.admittedCount == 10)
    }

    @Test func cooldownInterplayDoesNotClearOrExtendCooldown() async {
        let (throttle, clock) = makeThrottle()
        #expect(await throttle.waitForAdmission(key: "features|before|"))
        await throttle.enterCooldown()

        // Recording during cooldown does not clear cooldownEnd
        await throttle.recordQueryFetch(key: "features|bypass|")
        #expect(await throttle.waitForAdmission(key: "features|during|") == false)
        #expect(clock.elapsedMilliseconds == 0)

        // Advancing clock past 60 s expires cooldown normally (it was not extended)
        clock.advance(by: .seconds(61))
        #expect(await throttle.waitForAdmission(key: "features|during|"))
    }

    @Test func regressionGuardForInterleavedAdmissionsAndRecordedFetches() async {
        let (throttle, clock) = makeThrottle(minimumInterval: .seconds(1.5), windowCapacity: 28)
        var allEvents: [Int64] = []

        // Interleave 20 typed admissions and 15 recorded fetches over time
        for index in 0..<35 {
            if index % 3 == 0 {
                await throttle.recordQueryFetch()
                allEvents.append(clock.elapsedMilliseconds)
            } else {
                let admitted = await throttle.waitForAdmission(key: "key-\(index)")
                #expect(admitted)
                allEvents.append(clock.elapsedMilliseconds)
            }
        }

        // Assert that for every point in time from the typing perspective,
        // admissions within any 60 s sliding window never exceed windowCapacity
        for (index, start) in allEvents.enumerated() {
            let windowCount = allEvents.filter { $0 >= start && $0 < start + 60_000 }.count
            #expect(windowCount <= 28, "window starting at event \(index) had \(windowCount) admissions")
        }
    }

    private static func makeMockItem(id: String, title: String) -> [String: Any] {
        [
            "id": id,
            "appId": "app-1",
            "title": title,
            "description": "",
            "status": "planned",
            "voteCount": 0,
            "hasVoted": false,
            "commentCount": 0,
            "createdAt": "2026-01-01T00:00:00.000Z"
        ]
    }

    private static func makeThreePageMockHandler() -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            if request.url?.path.contains("/columns/") == true {
                let columnJSON: [String: Any] = [
                    "id": "col-1",
                    "appId": "app-1",
                    "name": "Planned",
                    "slug": "planned",
                    "position": 0,
                    "isVisible": true,
                    "isSystem": true,
                    "kind": "normal",
                    "createdAt": "2026-01-01T00:00:00.000Z",
                    "updatedAt": "2026-01-01T00:00:00.000Z"
                ]
                return (makeHTTPResponse(), try encodeJSON(["columns": [columnJSON]]))
            }
            let urlString = request.url?.absoluteString ?? ""
            if !urlString.contains("cursor=") {
                let items = [makeMockItem(id: "fr-1", title: "First")]
                return (makeHTTPResponse(), try encodeJSON([
                    "requests": items, "total": 3, "hasMore": true, "nextCursor": "page-2"
                ]))
            } else if urlString.contains("cursor=page-2") {
                let items = [makeMockItem(id: "fr-2", title: "Second")]
                return (makeHTTPResponse(), try encodeJSON([
                    "requests": items, "total": 3, "hasMore": true, "nextCursor": "page-3"
                ]))
            } else {
                let items = [makeMockItem(id: "fr-3", title: "Third")]
                return (makeHTTPResponse(), try encodeJSON([
                    "requests": items, "total": 3, "hasMore": false
                ]))
            }
        }
    }

    @Test func roadmapPaginationRecordsOncePerEmittedQueryPage() async throws {
        let (throttle, _) = makeThrottle()
        let host = "test-roadmap-accounting.example.com"
        MockURLProtocol.setHandler(forHost: host, Self.makeThreePageMockHandler())

        let client = makeClient(
            baseURL: URL(string: "https://\(host)")!,
            searchThrottle: throttle
        )

        let result = try await loadRoadmapGroups(
            client: client,
            userToken: "tok",
            query: "swift",
            config: nil
        )
        #expect(result != nil)
        #expect(await throttle.admittedCount == 3, "3 query pages fetched must record exactly 3 times in the throttle")
    }

    @Test func emptyQueryLoadsRecordNothingInThrottle() async throws {
        let (throttle, _) = makeThrottle()
        let host = "test-empty-query.example.com"
        MockURLProtocol.setHandler(forHost: host) { request in
            if request.url?.path.contains("/columns/") == true {
                return (makeHTTPResponse(), try encodeJSON(["columns": []]))
            }
            return (makeHTTPResponse(), try encodeJSON(["requests": [], "total": 0, "hasMore": false]))
        }

        let client = makeClient(
            baseURL: URL(string: "https://\(host)")!,
            searchThrottle: throttle
        )

        let result = try await loadRoadmapGroups(
            client: client,
            userToken: "tok",
            query: nil,
            config: nil
        )
        #expect(result != nil)
        #expect(await throttle.admittedCount == 0, "plain listing without query must not record in throttle")
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

@Suite("SearchAdmissionOutcome")
struct SearchAdmissionOutcomeTests {
    @Test func deniedAdmissionWithExistingContentPresentsInlineNotice() {
        let expected = CupThreadStrings.tr("cupthread.search.rate_limited")
        #expect(!expected.isEmpty)
        #expect(SearchAdmissionOutcome.outcome(isCancelled: false, hasExistingContent: true) == .inlineNotice(expected))
        #expect(
            SearchAdmissionOutcome.outcome(wasAdmitted: false, isCancelled: false, hasExistingContent: true)
                == .inlineNotice(expected)
        )
    }

    @Test func deniedAdmissionWithoutExistingContentPresentsFullScreenError() {
        let expected = CupThreadStrings.tr("cupthread.search.rate_limited")
        #expect(!expected.isEmpty)
        #expect(SearchAdmissionOutcome.outcome(isCancelled: false, hasExistingContent: false) == .fullScreenError(expected))
        #expect(
            SearchAdmissionOutcome.outcome(wasAdmitted: false, isCancelled: false, hasExistingContent: false)
                == .fullScreenError(expected)
        )
    }

    @Test func cancellationIsSuppressedRegardlessOfExistingContent() {
        #expect(SearchAdmissionOutcome.outcome(isCancelled: true, hasExistingContent: true) == nil)
        #expect(SearchAdmissionOutcome.outcome(isCancelled: true, hasExistingContent: false) == nil)
        #expect(SearchAdmissionOutcome.outcome(wasAdmitted: false, isCancelled: true, hasExistingContent: true) == nil)
        #expect(SearchAdmissionOutcome.outcome(wasAdmitted: false, isCancelled: true, hasExistingContent: false) == nil)
    }

    @Test func admittedFetchProducesNoDenialOutcome() {
        #expect(SearchAdmissionOutcome.outcome(wasAdmitted: true, isCancelled: false, hasExistingContent: true) == nil)
        #expect(SearchAdmissionOutcome.outcome(wasAdmitted: true, isCancelled: false, hasExistingContent: false) == nil)
        #expect(SearchAdmissionOutcome.outcome(wasAdmitted: true, isCancelled: true, hasExistingContent: true) == nil)
        #expect(SearchAdmissionOutcome.outcome(wasAdmitted: true, isCancelled: true, hasExistingContent: false) == nil)
    }
}
