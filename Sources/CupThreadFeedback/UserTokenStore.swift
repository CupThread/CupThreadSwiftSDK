import Foundation

/// Persists a stable anonymous user token across app launches.
/// Used to track vote state and own pending requests without requiring authentication.
public final class UserTokenStore: @unchecked Sendable {
    public static let shared = UserTokenStore()

    private let key = "com.cupthread.featureRequestUserToken"

    private init() {}

    /// Returns the existing token, or generates and persists a new UUID on first access.
    public var token: String {
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }
}
