import Foundation

/// The remembered changelog-subscription state for one app key.
///
/// Subscriptions are double opt-in: `subscribeToChangelog` only creates a
/// *pending* record and the address starts receiving changelog emails after
/// the emailed single-use confirmation link is submitted. Remembering the
/// phase keeps SDK surfaces from claiming "emails on" for a subscription
/// that was never confirmed (issue #273).
struct ChangelogSubscriptionRecord: Equatable, Sendable, Codable {
    /// Double-opt-in phase of the remembered subscription.
    enum State: Equatable, Sendable {
        /// Subscribe succeeded; the emailed confirmation is still outstanding.
        case pending(since: Date)
        /// Confirmed — or recorded by an SDK version predating the phase
        /// distinction, whose bare-email storage migrates here.
        case confirmed

        /// Whether the emailed confirmation is still outstanding.
        var isPending: Bool {
            if case .pending = self { return true }
            return false
        }
    }

    let email: String
    let state: State

    init(email: String, state: State) {
        self.email = email
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case email, state, since
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        email = try container.decode(String.self, forKey: .email)
        if try container.decode(String.self, forKey: .state) == "pending" {
            state = .pending(
                since: try container.decodeIfPresent(Date.self, forKey: .since)
                    ?? Date(timeIntervalSince1970: 0)
            )
        } else {
            state = .confirmed
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(email, forKey: .email)
        switch state {
        case .pending(let since):
            try container.encode("pending", forKey: .state)
            try container.encode(since, forKey: .since)
        case .confirmed:
            try container.encode("confirmed", forKey: .state)
        }
    }
}

/// Thread-safe persistent store for the changelog email-subscription state.
///
/// Remembers the subscription for this app key in `UserDefaults` under
/// `"com.cupthread.changelog.subscribedEmail.<appKey>"`, following the same
/// per-app-key scoping as `ChangelogSeenStore`. Records carry the address
/// plus its double-opt-in phase (`ChangelogSubscriptionRecord`); values
/// written by SDK versions that stored a bare email string read back as
/// `.confirmed`, preserving the subscribed rendering those versions promised.
///
/// The backend exposes no subscription-status query, so this local record is
/// the only way SDK surfaces can avoid re-prompting already-subscribed users
/// with a blank form on every launch. Subscriptions made outside the SDK
/// (web console) and unsubscriptions made via an emailed link are not
/// observed; the next successful in-app subscribe re-records the address.
final class ChangelogSubscriptionStore: @unchecked Sendable {
    /// Key prefix used in `UserDefaults`, followed by the app key.
    static let keyPrefix = "com.cupthread.changelog.subscribedEmail."

    let appKey: String
    let userDefaults: UserDefaults
    let storageKey: String

    private let lock = NSLock()

    init(appKey: String, userDefaults: UserDefaults = .standard) {
        self.appKey = appKey
        self.userDefaults = userDefaults
        self.storageKey = Self.keyPrefix + appKey
    }

    /// The remembered subscription with its double-opt-in phase, or `nil`
    /// when nothing is recorded.
    func subscriptionRecord() -> ChangelogSubscriptionRecord? {
        lock.lock()
        defer { lock.unlock() }
        return Self.record(fromStoredValue: userDefaults.string(forKey: storageKey))
    }

    /// The remembered subscription address regardless of its phase, or `nil`
    /// when nothing is recorded.
    func subscribedEmail() -> String? {
        subscriptionRecord()?.email
    }

    /// Records the subscription with its double-opt-in phase. The address is
    /// trimmed; whitespace-only input is ignored.
    func persist(record: ChangelogSubscriptionRecord) {
        let trimmed = record.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = try? JSONEncoder().encode(
                  ChangelogSubscriptionRecord(email: trimmed, state: record.state)
              ),
              let serialized = String(data: data, encoding: .utf8) else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        userDefaults.set(serialized, forKey: storageKey)
    }

    /// Removes the remembered subscription.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        userDefaults.removeObject(forKey: storageKey)
    }

    /// A bare-email string written before the phase distinction is a
    /// `.confirmed` record; a JSON-serialized record decodes as written.
    /// A bare address can never be valid record JSON, so the fallback is
    /// unambiguous.
    private static func record(fromStoredValue raw: String?) -> ChangelogSubscriptionRecord? {
        guard let raw, !raw.isEmpty else { return nil }
        if let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(ChangelogSubscriptionRecord.self, from: data) {
            return decoded
        }
        return ChangelogSubscriptionRecord(email: raw, state: .confirmed)
    }
}
