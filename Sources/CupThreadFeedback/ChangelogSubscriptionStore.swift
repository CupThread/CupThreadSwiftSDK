import Foundation

/// Thread-safe persistent store for the changelog email-subscription state.
///
/// Remembers the email address subscribed to changelog notifications in
/// `UserDefaults` under `"com.cupthread.changelog.subscribedEmail.<appKey>"`,
/// following the same per-app-key scoping as `ChangelogSeenStore`.
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

    /// The remembered subscribed email, or `nil` when nothing is recorded.
    func subscribedEmail() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return userDefaults.string(forKey: storageKey)
    }

    /// Records the subscribed email, trimmed. Whitespace-only input is ignored.
    func persist(email: String) {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        userDefaults.set(trimmed, forKey: storageKey)
    }

    /// Removes the remembered subscription.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        userDefaults.removeObject(forKey: storageKey)
    }
}
