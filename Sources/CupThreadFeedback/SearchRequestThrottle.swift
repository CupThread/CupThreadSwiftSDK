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
/// Plain listings (no query) bypass the throttle completely — the backend does not
/// rate-limit them. User-initiated loads (pull-to-refresh, retry buttons, deep pagination)
/// bypass waiting so the throttle can never strand a deliberate action, but query-bearing
/// fetches are recorded (via ``recordQueryFetch(key:)``) so the sliding window accurately
/// tracks them against the per-IP budget.
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

    /// Suspends until a query-bearing fetch for `key` may hit the network,
    /// returning the admission verdict.
    ///
    /// Returns:
    /// - `.admitted` when admission is granted and a budget slot is committed.
    /// - `.duplicateSkipped` when `key` matches the last admitted fetch.
    /// - `.rateLimited` when an HTTP 429 cooldown is currently active.
    /// - `nil` when the task was cancelled while waiting.
    func admissionVerdict(key: String) async -> SearchAdmissionVerdict? {
        while true {
            guard !Task.isCancelled else { return nil }
            if let cooldownEnd, now() < cooldownEnd { return .rateLimited }
            if key == lastAdmittedKey { return .duplicateSkipped }
            if let last = lastAdmittedAt, now() - last < minimumInterval {
                guard await sleepUntilAllowingCancel(last + minimumInterval) else { return nil }
                continue
            }
            admittedTimes.removeAll { now() - $0 >= windowPeriod }
            if admittedTimes.count >= windowCapacity, let oldest = admittedTimes.first {
                guard await sleepUntilAllowingCancel(oldest + windowPeriod) else { return nil }
                continue
            }
            let admittedAt = now()
            lastAdmittedAt = admittedAt
            lastAdmittedKey = key
            admittedTimes.append(admittedAt)
            return .admitted
        }
    }

    /// Suspends until a query-bearing fetch for `key` may hit the network.
    ///
    /// Returns `true` when admitted, or `false` when skipped (duplicate query,
    /// active cooldown, or task cancellation). A cancelled or skipped wait
    /// records no reservation — only a `true` return commits a budget slot, so
    /// callers must perform the network call exactly when this returns `true`.
    func waitForAdmission(key: String) async -> Bool {
        await admissionVerdict(key: key) == .admitted
    }

    /// Whether `key` duplicates the last admitted search key.
    func isDuplicateKey(_ key: String) -> Bool {
        key == lastAdmittedKey
    }

    /// Records a query-bearing fetch that already happened (or is about to)
    /// without suspending — user-initiated loads are never delayed, but they
    /// still spend the per-IP budget, so the window must reflect them.
    func recordQueryFetch(key: String? = nil) {
        admittedTimes.removeAll { now() - $0 >= windowPeriod }
        admittedTimes.append(now())
        if let key {
            lastAdmittedKey = key
            lastAdmittedAt = now()
        }
    }

    /// Number of admitted query-bearing fetches currently within the sliding window.
    var admittedCount: Int {
        admittedTimes.filter { now() - $0 < windowPeriod }.count
    }

    /// Starts the post-429 cooldown and clears the duplicate gate, so the
    /// first emission after the cooldown proceeds even for the same query —
    /// the failed search never rendered results for it.
    func enterCooldown() {
        cooldownEnd = now() + cooldownDuration
        lastAdmittedKey = nil
    }

    /// Clears the recorded last admitted key, allowing the subsequent query to be
    /// admitted even if it matches the previously searched key (e.g. after the user
    /// cleared the search field or refreshed the listing).
    func resetLastAdmittedKey() {
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

// MARK: - Cancellation classification

extension Error {
    /// Whether this error is task cancellation rather than a failure.
    ///
    /// SwiftUI restarts (and therefore cancels) `.task(id:)` work on every
    /// search keystroke and cancels it when the view disappears, and
    /// `URLSession` surfaces that cancellation as `URLError(.cancelled)` (or
    /// the request itself is torn down the same way). A cancelled load never
    /// reached a verdict, so surfaces must treat it as "nothing happened" —
    /// keep the rendered content and every state flag — instead of
    /// presenting an error the user cannot act on.
    var isSdkCancellation: Bool {
        if self is CancellationError { return true }
        if let urlError = self as? URLError { return urlError.code == .cancelled }
        return false
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
///
/// Cancellation is not a failure: ``outcome(for:hasExistingContent:)``
/// returns `nil` for it and the caller must leave the surface's content and
/// state flags untouched.
enum SearchReloadOutcome: Equatable {
    /// Previous results stay visible; show this message as a transient notice.
    case inlineNotice(String)
    /// Nothing to show — present the full-screen error view with this message.
    case fullScreenError(String)

    /// - Parameters:
    ///   - error: The error the reload threw.
    ///   - hasExistingContent: Whether the surface already shows results.
    /// - Returns: `nil` when `error` is task cancellation
    ///   (``Error/isSdkCancellation``) — the reload was superseded or the
    ///   surface dismissed, and no failure state may be written.
    static func outcome(for error: Error, hasExistingContent: Bool) -> SearchReloadOutcome? {
        guard !error.isSdkCancellation else { return nil }
        let message: String
        if let clientError = error as? FeedbackClientError, case .rateLimited = clientError {
            message = CupThreadStrings.tr("cupthread.search.rate_limited")
        } else {
            message = FriendlyError.message(for: error)
        }
        return hasExistingContent ? .inlineNotice(message) : .fullScreenError(message)
    }
}

// MARK: - Search admission verdict

/// The verdict of evaluating a query-bearing search against the throttle budget.
enum SearchAdmissionVerdict: Equatable, Sendable {
    /// The fetch is granted admission and its budget slot has been recorded.
    case admitted
    /// The query matches the last admitted fetch and is skipped as a duplicate.
    case duplicateSkipped
    /// An active HTTP 429 cooldown is suppressing query-bearing searches.
    case rateLimited
}

// MARK: - Search admission outcome presentation

/// How a denied search-throttle admission should be presented.
///
/// When the throttle denies a query-bearing fetch due to an active 429 cooldown,
/// the surface explains to the user why the search did not run.
///
/// Benign duplicate query skips and task cancellations remain completely silent
/// (no notice or full-screen error).
///
/// When previous results are visible, the denial becomes a transient inline
/// notice; on a fresh surface with nothing to show, it presents the full-screen
/// error view so the user does not see a bare skeleton or empty state.
enum SearchAdmissionOutcome: Equatable {
    /// Previous results stay visible; show this message as a transient notice.
    case inlineNotice(String)
    /// Nothing to show — present the full-screen error view with this message.
    case fullScreenError(String)

    /// Derives the presentation for an admission verdict.
    ///
    /// - Parameters:
    ///   - verdict: The admission verdict from the search throttle.
    ///   - hasExistingContent: Whether the surface already shows results.
    /// - Returns: `nil` if admitted or duplicate-skipped; otherwise the outcome for rate limiting.
    static func outcome(
        for verdict: SearchAdmissionVerdict,
        hasExistingContent: Bool
    ) -> SearchAdmissionOutcome? {
        switch verdict {
        case .admitted, .duplicateSkipped:
            return nil
        case .rateLimited:
            let message = CupThreadStrings.tr("cupthread.search.rate_limited")
            return hasExistingContent ? .inlineNotice(message) : .fullScreenError(message)
        }
    }

    /// Derives the presentation for an optional admission verdict (where `nil` represents task cancellation).
    ///
    /// - Parameters:
    ///   - verdict: The optional admission verdict from the search throttle.
    ///   - hasExistingContent: Whether the surface already shows results.
    /// - Returns: `nil` if `verdict` is `nil`, `.admitted`, or `.duplicateSkipped`; otherwise the outcome for rate limiting.
    static func outcome(
        for verdict: SearchAdmissionVerdict?,
        hasExistingContent: Bool
    ) -> SearchAdmissionOutcome? {
        guard let verdict else { return nil }
        return outcome(for: verdict, hasExistingContent: hasExistingContent)
    }

    /// Derives the presentation for an admission denial.
    ///
    /// - Parameters:
    ///   - isCancelled: Whether the calling task was cancelled (superseded keystroke).
    ///   - hasExistingContent: Whether the surface already shows results.
    ///   - isDuplicate: Whether the fetch was skipped as a duplicate query.
    /// - Returns: `nil` when `isCancelled` or `isDuplicate` is `true`; otherwise the outcome for the denial.
    static func outcome(
        isCancelled: Bool,
        hasExistingContent: Bool,
        isDuplicate: Bool = false
    ) -> SearchAdmissionOutcome? {
        guard !isCancelled, !isDuplicate else { return nil }
        let message = CupThreadStrings.tr("cupthread.search.rate_limited")
        return hasExistingContent ? .inlineNotice(message) : .fullScreenError(message)
    }

    /// Derives the presentation for an admission verdict.
    ///
    /// - Parameters:
    ///   - wasAdmitted: Whether the throttle admitted the fetch.
    ///   - isCancelled: Whether the calling task was cancelled (superseded keystroke).
    ///   - hasExistingContent: Whether the surface already shows results.
    ///   - isDuplicate: Whether the fetch was skipped as a duplicate query.
    /// - Returns: `nil` if admitted, cancelled, or duplicate-skipped; otherwise the outcome for the denial.
    static func outcome(
        wasAdmitted: Bool,
        isCancelled: Bool,
        hasExistingContent: Bool,
        isDuplicate: Bool = false
    ) -> SearchAdmissionOutcome? {
        guard !wasAdmitted, !isDuplicate else { return nil }
        return outcome(isCancelled: isCancelled, hasExistingContent: hasExistingContent, isDuplicate: isDuplicate)
    }

    /// Explicitly returns `nil` for duplicate query skips so duplicate fetches never
    /// trigger a rate-limiting notice.
    static func outcomeForDuplicateSkip() -> SearchAdmissionOutcome? {
        nil
    }
}
