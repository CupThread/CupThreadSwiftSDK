import Foundation

// MARK: - Search request throttle (search rate-limit budget, per-IP)

/// Shared gate for query-bearing feature-request searches.
///
/// The production API rate-limits search requests to 30 per 60 s per client
/// IP, and personalized searches (the SDK always sends its `userToken`)
/// never hit the backend's shared search cache. Sustained search-as-you-type
/// could therefore lock the user — and everyone sharing their egress IP —
/// out with HTTP 429.
///
/// ``FeatureRequestsView`` and ``RoadmapBoardView`` admit their
/// query-bearing fetches through one throttle per ``FeedbackClient`` so the
/// two surfaces share a single budget:
///
/// - At least `minimumInterval` (1.5 s) between admitted fetches.
/// - At most `windowCapacity` (28, strictly below the server's 30) admitted
///   fetches in any `windowPeriod` (60 s) sliding window.
/// - A fetch whose key (trimmed query plus version filter) matches the last
///   admitted fetch is skipped outright — re-emitting an unchanged query
///   never re-hits the network.
/// - After an HTTP 429 the throttle enters a `cooldownDuration` (60 s)
///   during which query-bearing admissions are denied; the next emission
///   after the cooldown resumes searching.
///
/// Plain listings (no query) bypass the throttle — the backend does not
/// rate-limit them. User-initiated loads (pull-to-refresh, retry buttons)
/// bypass it too, so the throttle can never strand a deliberate action.
actor SearchRequestThrottle {
    private let minimumInterval: Duration
    private let windowPeriod: Duration
    private let windowCapacity: Int
    private let cooldownDuration: Duration

    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void

    private var lastAdmittedAt: ContinuousClock.Instant?
    private var lastAdmittedKey: String?
    private var admittedTimes: [ContinuousClock.Instant] = []
    private var cooldownEnd: ContinuousClock.Instant?

    /// - Parameters:
    ///   - minimumInterval: Minimum spacing between admitted query-bearing fetches.
    ///   - windowPeriod: Sliding window over which admissions are capped.
    ///   - windowCapacity: Admissions allowed per `windowPeriod`.
    ///   - cooldownDuration: How long an HTTP 429 suppresses admissions.
    ///   - now: Current time; injectable so tests can drive virtual time.
    ///   - sleepUntil: Suspends until the given instant (throws on task
    ///     cancellation); injectable so tests run on virtual time.
    init(
        minimumInterval: Duration = .seconds(1.5),
        windowPeriod: Duration = .seconds(60),
        windowCapacity: Int = 28,
        cooldownDuration: Duration = .seconds(60),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now },
        sleepUntil: (@Sendable (ContinuousClock.Instant) async throws -> Void)? = nil
    ) {
        self.minimumInterval = minimumInterval
        self.windowPeriod = windowPeriod
        self.windowCapacity = windowCapacity
        self.cooldownDuration = cooldownDuration
        self.now = now
        self.sleepUntil = sleepUntil ?? { deadline in
            try await ContinuousClock().sleep(until: deadline, tolerance: .none)
        }
    }

    /// Suspends until a query-bearing fetch for `key` may hit the network.
    ///
    /// Returns `false` when the fetch should be skipped: a 429 cooldown is
    /// active, the key duplicates the last admitted fetch, or the task was
    /// cancelled while waiting. A cancelled or skipped wait records no
    /// reservation — only a `true` return commits a budget slot, so callers
    /// must perform the network call exactly when this returns `true`.
    func waitForAdmission(key: String) async -> Bool {
        while true {
            guard !Task.isCancelled else { return false }
            if let cooldownEnd, now() < cooldownEnd { return false }
            if key == lastAdmittedKey { return false }
            if let last = lastAdmittedAt, now() - last < minimumInterval {
                guard await sleepUntilAllowingCancel(last + minimumInterval) else { return false }
                continue
            }
            admittedTimes.removeAll { now() - $0 >= windowPeriod }
            if admittedTimes.count >= windowCapacity, let oldest = admittedTimes.first {
                guard await sleepUntilAllowingCancel(oldest + windowPeriod) else { return false }
                continue
            }
            let admittedAt = now()
            lastAdmittedAt = admittedAt
            lastAdmittedKey = key
            admittedTimes.append(admittedAt)
            return true
        }
    }

    /// Starts the post-429 cooldown and clears the duplicate gate, so the
    /// first emission after the cooldown proceeds even for the same query —
    /// the failed search never rendered results for it.
    func enterCooldown() {
        cooldownEnd = now() + cooldownDuration
        lastAdmittedKey = nil
    }

    private func sleepUntilAllowingCancel(_ deadline: ContinuousClock.Instant) async -> Bool {
        do {
            try await sleepUntil(deadline)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Reload failure presentation

/// How a failed list or board reload should be presented.
///
/// A reload failure must never wipe already-rendered content (the old
/// behavior swapped the whole list for the error view, and while the user
/// kept typing, the list and the error placeholder blinked alternately).
/// When results are on screen the failure becomes a transient inline notice
/// instead; only a failure with nothing to show fills the surface with the
/// full-screen error view.
enum SearchReloadOutcome: Equatable {
    /// Previous results stay visible; show this message as a transient notice.
    case inlineNotice(String)
    /// Nothing to show — present the full-screen error view with this message.
    case fullScreenError(String)

    /// - Parameters:
    ///   - error: The error the reload threw.
    ///   - hasExistingContent: Whether the surface already shows results.
    static func outcome(for error: Error, hasExistingContent: Bool) -> SearchReloadOutcome {
        let message: String
        if let clientError = error as? FeedbackClientError, case .rateLimited = clientError {
            message = CupThreadStrings.tr("cupthread.search.rate_limited")
        } else {
            message = error.localizedDescription
        }
        return hasExistingContent ? .inlineNotice(message) : .fullScreenError(message)
    }
}
