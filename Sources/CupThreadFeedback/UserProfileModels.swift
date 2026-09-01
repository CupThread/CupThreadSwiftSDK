import Foundation

// MARK: - User profile

/// A public developer or user profile.
///
/// Returned as part of ``PublicUserProfileResponse`` from
/// `GET /api/v1/users/{userId}/profile`.
public struct UserProfile: Codable, Equatable, Sendable {
    /// Clerk user id.
    public let clerkUserId: String
    /// Display name, when set.
    public let displayName: String?
    /// Avatar image URL, when set.
    public let avatarUrl: String?
    /// Short bio, when set.
    public let bio: String?
    /// Personal or project website URL, when set.
    public let websiteUrl: String?
    /// Whether the user has chosen to hide their comment history.
    public let hideComments: Bool
    /// ISO-8601 account creation timestamp.
    public let createdAt: String?
    /// ISO-8601 last-update timestamp.
    public let updatedAt: String?
}

// MARK: - Profile response

/// A recent public comment shown on a user's profile page.
public struct UserProfileComment: Codable, Equatable, Identifiable, Sendable {
    /// Stable comment id.
    public let id: String
    /// The comment body text.
    public let body: String
    /// ISO-8601 creation timestamp.
    public let createdAt: String
    /// Id of the feature request the comment belongs to.
    public let featureRequestId: String
    /// Title of the feature request the comment belongs to.
    public let featureRequestTitle: String
    /// App id the feature request belongs to.
    public let appId: String
    /// App name the feature request belongs to.
    public let appName: String
}

/// Response to `GET /api/v1/users/{userId}/profile`.
public struct PublicUserProfileResponse: Codable, Equatable, Sendable {
    /// The user's public profile.
    public let profile: UserProfile
    /// Public apps associated with this user.
    public let apps: [PublicAppSummary]
    /// Recent public comments by this user.
    public let recentComments: [UserProfileComment]
    /// Whether the user has chosen to hide their comment history.
    public let hideComments: Bool
}

// MARK: - Public app summary

/// Summary of a public app, as returned in user profile or showcase responses.
public struct PublicAppSummary: Codable, Equatable, Identifiable, Sendable {
    /// App id.
    public let id: String
    /// App display name.
    public let name: String
    /// URL-safe slug.
    public let slug: String
    /// App icon URL, when set.
    public let iconUrl: String?
    /// App description, when set.
    public let description: String?
    /// Total feature request count.
    public let requestCount: Int
}
