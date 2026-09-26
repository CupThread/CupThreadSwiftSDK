import Foundation

// MARK: - User profile

/// A public developer or user profile.
///
/// Returned as part of ``PublicUserProfileResponse`` from
/// `GET /api/v1/users/{userId}/profile`.
public struct UserProfile: Codable, Equatable, Sendable {
    /// App-scoped pseudonymous user identifier (e.g. `u_ab12cd34`).
    ///
    /// Public endpoints no longer expose global identity-provider IDs. The
    /// value is stable within a single app but is not comparable across
    /// apps or tenants: do not assume a `user_` prefix and do not correlate
    /// it with identifiers from other `appKey` instances.
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

    /// Creates a new user profile instance.
    public init(
        clerkUserId: String,
        displayName: String? = nil,
        avatarUrl: String? = nil,
        bio: String? = nil,
        websiteUrl: String? = nil,
        hideComments: Bool = false,
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.clerkUserId = clerkUserId
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.bio = bio
        self.websiteUrl = websiteUrl
        self.hideComments = hideComments
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case clerkUserId, displayName, avatarUrl, bio, websiteUrl, hideComments, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clerkUserId = try container.decode(String.self, forKey: .clerkUserId)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        avatarUrl = try container.decodeIfPresent(String.self, forKey: .avatarUrl)
        bio = try container.decodeIfPresent(String.self, forKey: .bio)
        websiteUrl = try container.decodeIfPresent(String.self, forKey: .websiteUrl)
        hideComments = try container.decodeIfPresent(Bool.self, forKey: .hideComments) ?? false
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    }
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
    /// App id the feature request belongs to, when available.
    public let appId: String?
    /// App name the feature request belongs to.
    public let appName: String
    /// Workspace slug the feature request belongs to, when available.
    public let workspaceSlug: String?
    /// App slug the feature request belongs to, when available.
    public let appSlug: String?

    /// Creates a new user profile comment instance.
    public init(
        id: String,
        body: String,
        createdAt: String,
        featureRequestId: String,
        featureRequestTitle: String,
        appId: String? = nil,
        appName: String,
        workspaceSlug: String? = nil,
        appSlug: String? = nil
    ) {
        self.id = id
        self.body = body
        self.createdAt = createdAt
        self.featureRequestId = featureRequestId
        self.featureRequestTitle = featureRequestTitle
        self.appId = appId
        self.appName = appName
        self.workspaceSlug = workspaceSlug
        self.appSlug = appSlug
    }

    private enum CodingKeys: String, CodingKey {
        case id, body, createdAt, featureRequestId, featureRequestTitle, appId, appName, workspaceSlug, appSlug
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        body = try container.decode(String.self, forKey: .body)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        featureRequestId = try container.decode(String.self, forKey: .featureRequestId)
        featureRequestTitle = try container.decode(String.self, forKey: .featureRequestTitle)
        appId = try container.decodeIfPresent(String.self, forKey: .appId)
        appName = try container.decode(String.self, forKey: .appName)
        workspaceSlug = try container.decodeIfPresent(String.self, forKey: .workspaceSlug)
        appSlug = try container.decodeIfPresent(String.self, forKey: .appSlug)
    }
}

/// Response to `GET /api/v1/users/{userId}/profile`.
///
/// Public profiles are opt-in: for a user who has not created a public
/// profile the server returns an empty profile (`displayName` is `null`,
/// `publicApps` and `recentComments` are empty), and unknown identifiers
/// yield a `404` (surfaced as
/// ``FeedbackClientError/userProfileNotFound(message:)``). The endpoint is
/// rate-limited per client IP; a spent budget yields a `429` (surfaced as
/// ``FeedbackClientError/rateLimited(message:requestId:)`` — back off and
/// retry).
public struct PublicUserProfileResponse: Codable, Equatable, Sendable {
    /// The user's public profile.
    public let profile: UserProfile
    /// Public apps associated with this user.
    public let apps: [PublicAppSummary]
    /// Alias for ``apps`` matching the backend's `publicApps` field name.
    public var publicApps: [PublicAppSummary] { apps }
    /// Recent public comments by this user.
    public let recentComments: [UserProfileComment]
    /// Whether the user has chosen to hide their comment history.
    public let hideComments: Bool

    /// Creates a new user profile response instance.
    public init(
        profile: UserProfile,
        apps: [PublicAppSummary] = [],
        recentComments: [UserProfileComment] = [],
        hideComments: Bool? = nil
    ) {
        self.profile = profile
        self.apps = apps
        self.recentComments = recentComments
        self.hideComments = hideComments ?? profile.hideComments
    }

    private enum CodingKeys: String, CodingKey {
        case profile, publicApps, apps, recentComments, hideComments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profile = try container.decode(UserProfile.self, forKey: .profile)
        apps = try container.decodeIfPresent([PublicAppSummary].self, forKey: .publicApps)
            ?? (try container.decodeIfPresent([PublicAppSummary].self, forKey: .apps))
            ?? []
        recentComments = try container.decodeIfPresent([UserProfileComment].self, forKey: .recentComments) ?? []
        hideComments = try container.decodeIfPresent(Bool.self, forKey: .hideComments) ?? profile.hideComments
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(profile, forKey: .profile)
        try container.encode(apps, forKey: .publicApps)
        try container.encode(recentComments, forKey: .recentComments)
        try container.encode(hideComments, forKey: .hideComments)
    }
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
    /// App URL slug alias for ``slug``.
    public var appSlug: String { slug }
    /// App icon URL, when set.
    public let iconUrl: String?
    /// App description, when set.
    public let description: String?
    /// Total feature request count, when available.
    public let requestCount: Int?
    /// Workspace slug the app belongs to, when present.
    public let workspaceSlug: String?
    /// Workspace display name, when present.
    public let workspaceName: String?

    /// Creates a new public app summary instance.
    public init(
        id: String,
        name: String,
        slug: String,
        iconUrl: String? = nil,
        description: String? = nil,
        requestCount: Int? = nil,
        workspaceSlug: String? = nil,
        workspaceName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.iconUrl = iconUrl
        self.description = description
        self.requestCount = requestCount
        self.workspaceSlug = workspaceSlug
        self.workspaceName = workspaceName
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, slug, appSlug, iconUrl, description, requestCount, workspaceSlug, workspaceName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        slug = try container.decodeIfPresent(String.self, forKey: .appSlug)
            ?? (try container.decodeIfPresent(String.self, forKey: .slug))
            ?? ""
        iconUrl = try container.decodeIfPresent(String.self, forKey: .iconUrl)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        requestCount = try container.decodeIfPresent(Int.self, forKey: .requestCount)
        workspaceSlug = try container.decodeIfPresent(String.self, forKey: .workspaceSlug)
        workspaceName = try container.decodeIfPresent(String.self, forKey: .workspaceName)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(slug, forKey: .slug)
        try container.encode(slug, forKey: .appSlug)
        try container.encodeIfPresent(iconUrl, forKey: .iconUrl)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(requestCount, forKey: .requestCount)
        try container.encodeIfPresent(workspaceSlug, forKey: .workspaceSlug)
        try container.encodeIfPresent(workspaceName, forKey: .workspaceName)
    }
}
