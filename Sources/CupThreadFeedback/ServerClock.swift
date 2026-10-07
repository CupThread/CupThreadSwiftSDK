import Foundation

// MARK: - Server clock offset tracking (API-19)

/// Learns the API's clock from response `Date` headers so requests that carry
/// a signature timestamp stay inside the server's ±300 s freshness window
/// even when the device clock is wrong (issue #279 / API-19).
///
/// The offset is the latest observation of `serverDate - deviceNow` at the
/// moment a response arrived; ``correctedNow()`` applies it to the device
/// clock. It is a reference type created once per ``FeedbackClient``, so
/// struct copies of a client share one learned offset — mirroring the shared
/// search throttle and config cache. Devices whose clock is correct learn an
/// offset of ≈0 and behavior is unchanged.
final class ServerClock: @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var latestOffset: TimeInterval?

    /// - Parameter now: The device clock; injectable so tests can skew it.
    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    // DateFormatter is documented thread-safe for formatting since
    // macOS 10.9 / iOS 7, and only ever used read-only here.
    nonisolated(unsafe) private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        // RFC 1123 IMF-fixdate, the HTTP `Date` header format.
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    /// Parses an RFC 1123 HTTP `Date` header value (e.g.
    /// `"Tue, 07 Oct 2026 12:00:00 GMT"`); `nil` when unparseable.
    static func httpDate(_ value: String) -> Date? {
        httpDateFormatter.date(from: value)
    }

    /// Records a fresh observation of the server's time: the offset becomes
    /// `serverDate - deviceNow` as of this call, replacing any earlier one.
    func record(serverDate: Date) {
        lock.lock()
        defer { lock.unlock() }
        latestOffset = serverDate.timeIntervalSince(now())
    }

    /// Whether any response `Date` has been observed on this client.
    var hasObservation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return latestOffset != nil
    }

    /// The device clock corrected by the latest observed server offset
    /// (uncorrected — identical to the device clock — before any observation).
    func correctedNow() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return now().addingTimeInterval(latestOffset ?? 0)
    }
}
