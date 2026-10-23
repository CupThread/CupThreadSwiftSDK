import Foundation

// MARK: - User profile

/// A public developer or user profile.
///
/// Returned as part of ``PublicUserProfileResponse`` from
/// `GET /api/v1/users/{userId}/profile`.
public struct UserProfile: Codable, Equatable, Sendable {
    /// App-scoped pseudonymous user identifier (e.g. `u_ab12cd34ef567890abcdef1234567890`).
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
    /// Retired: the corrected public profile payload never carries this key
    /// (comment visibility is applied server-side). Kept for source
    /// compatibility and always `false` (issue #505).
    public var hideComments: Bool { false }
    /// ISO-8601 account creation timestamp, when served.
    public let createdAt: String?
    /// Retired: the corrected public profile payload never carries this key.
    /// Kept for source compatibility and always `nil` (issue #505).
    public var updatedAt: String? { nil }

    /// Creates a new user profile instance.
    ///
    /// `hideComments` and `updatedAt` are accepted but ignored: the corrected
    /// `UserProfile` component has only the six documented keys (issue #505).
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
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case clerkUserId, displayName, avatarUrl, bio, websiteUrl, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // All six keys are required by the corrected component; the four
        // nullable ones accept an explicit null but not an absent key
        // (issue #505).
        clerkUserId = try container.decode(String.self, forKey: .clerkUserId)
        displayName = try container.decode(String?.self, forKey: .displayName)
        avatarUrl = try container.decode(String?.self, forKey: .avatarUrl)
        bio = try container.decode(String?.self, forKey: .bio)
        websiteUrl = try container.decode(String?.self, forKey: .websiteUrl)
        createdAt = try container.decode(String.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Write required-nullable keys as explicit nulls so a round trip
        // produces a payload the corrected decoder accepts (issue #505).
        try container.encode(clerkUserId, forKey: .clerkUserId)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(avatarUrl, forKey: .avatarUrl)
        try container.encode(bio, forKey: .bio)
        try container.encode(websiteUrl, forKey: .websiteUrl)
        guard let createdAt else {
            // The contract requires a non-null timestamp, so emitting null
            // would create a payload this model cannot decode.
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.createdAt],
                    debugDescription: "UserProfile.createdAt is required by the public profile contract"
                )
            )
        }
        try container.encode(createdAt, forKey: .createdAt)
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
    /// Retired: the corrected profile comment never carries an app id. Kept
    /// for source compatibility and always `nil` (issue #505).
    public var appId: String? { nil }
    /// App name the feature request belongs to.
    public let appName: String
    /// Workspace slug the feature request belongs to.
    ///
    /// Required on the corrected wire; optional here so existing callers
    /// that read it as an optional keep compiling (issue #505).
    public let workspaceSlug: String?
    /// App slug the feature request belongs to.
    ///
    /// Required on the corrected wire; optional here so existing callers
    /// that read it as an optional keep compiling (issue #505).
    public let appSlug: String?

    /// Creates a new user profile comment instance.
    ///
    /// `appId` is accepted but ignored: the corrected profile comment has no
    /// app id (issue #505).
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
        self.appName = appName
        self.workspaceSlug = workspaceSlug
        self.appSlug = appSlug
    }

    private enum CodingKeys: String, CodingKey {
        case id, body, createdAt, featureRequestId, featureRequestTitle, appName, workspaceSlug, appSlug
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        body = try container.decode(String.self, forKey: .body)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        featureRequestId = try container.decode(String.self, forKey: .featureRequestId)
        featureRequestTitle = try container.decode(String.self, forKey: .featureRequestTitle)
        appName = try container.decode(String.self, forKey: .appName)
        // Required on the corrected wire: a missing slug is contract drift,
        // so surface it instead of decoding a silently unscoped comment.
        workspaceSlug = try container.decode(String.self, forKey: .workspaceSlug)
        appSlug = try container.decode(String.self, forKey: .appSlug)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(body, forKey: .body)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(featureRequestId, forKey: .featureRequestId)
        try container.encode(featureRequestTitle, forKey: .featureRequestTitle)
        try container.encode(appName, forKey: .appName)
        guard let workspaceSlug else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.workspaceSlug],
                    debugDescription: "UserProfileComment.workspaceSlug is required by the public profile contract"
                )
            )
        }
        try container.encode(workspaceSlug, forKey: .workspaceSlug)
        guard let appSlug else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.appSlug],
                    debugDescription: "UserProfileComment.appSlug is required by the public profile contract"
                )
            )
        }
        try container.encode(appSlug, forKey: .appSlug)
    }
}

/// Response to `GET /api/v1/users/{userId}/profile`.
///
/// Public profiles are opt-in: for a user who has not created a public
/// profile the server returns an empty profile (`displayName` is `null`,
/// `publicApps` and `recentComments` are empty), and unknown pseudonyms
/// yield a `404` (surfaced as
/// ``FeedbackClientError/userProfileNotFound(message:requestId:)``). The
/// endpoint resolves app-scoped pseudonyms only (PRIV-06, SaaS#1322), so
/// ``FeedbackClient/fetchUserProfile(userId:)`` rejects raw Clerk ids and
/// other identifier shapes locally instead of dispatching them. The endpoint
/// is rate-limited per client IP; a spent budget yields a `429` (surfaced as
/// ``FeedbackClientError/rateLimited(message:requestId:)`` — back off and
/// retry).
public struct PublicUserProfileResponse: Codable, Equatable, Sendable {
    /// The user's public profile.
    public let profile: UserProfile
    /// Public apps associated with this user.
    ///
    /// The corrected `PublicUserProfileResponse` serves this collection as a
    /// required `publicApps` array (issue #505).
    public let publicApps: [PublicAppSummary]
    /// Legacy alias for ``publicApps``.
    public var apps: [PublicAppSummary] { publicApps }
    /// Recent public comments by this user.
    ///
    /// Always served; a user who hides comments receives an empty array.
    public let recentComments: [UserProfileComment]
    /// Retired: the corrected payload never carries this key; comment
    /// visibility is applied server-side. Kept for source compatibility and
    /// always `false` (issue #505).
    public var hideComments: Bool { false }

    /// Creates a new user profile response instance using the legacy `apps`
    /// label. `hideComments` is accepted but ignored (issue #505).
    public init(
        profile: UserProfile,
        apps: [PublicAppSummary] = [],
        recentComments: [UserProfileComment] = [],
        hideComments: Bool? = nil
    ) {
        self.profile = profile
        self.publicApps = apps
        self.recentComments = recentComments
    }

    /// Creates a new user profile response instance using the corrected
    /// `publicApps` label.
    public init(
        profile: UserProfile,
        publicApps: [PublicAppSummary],
        recentComments: [UserProfileComment] = []
    ) {
        self.profile = profile
        self.publicApps = publicApps
        self.recentComments = recentComments
    }

    private enum CodingKeys: String, CodingKey {
        case profile, publicApps, recentComments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profile = try container.decode(UserProfile.self, forKey: .profile)
        // Required on the corrected wire: a renamed or dropped collection is
        // contract drift, not an empty profile (#505).
        publicApps = try container.decode([PublicAppSummary].self, forKey: .publicApps)
        recentComments = try container.decode([UserProfileComment].self, forKey: .recentComments)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(profile, forKey: .profile)
        try container.encode(publicApps, forKey: .publicApps)
        try container.encode(recentComments, forKey: .recentComments)
    }
}

// MARK: - Public app summary

/// Summary of a public app, as returned in a user profile's `publicApps`.
///
/// Mirrors the corrected `PublicUserProfileApp` component (issue #505):
/// `id`, `workspaceSlug`, `workspaceName`, `appSlug`, `name`, and nullable
/// `description`/`iconUrl`.
public struct PublicAppSummary: Codable, Equatable, Identifiable, Sendable {
    /// App id.
    public let id: String
    /// App display name.
    public let name: String
    /// URL-safe app slug (the corrected `PublicUserProfileApp.appSlug`).
    public let appSlug: String
    /// Legacy alias for ``appSlug``.
    public var slug: String { appSlug }
    /// App icon URL, when set.
    public let iconUrl: String?
    /// App description, when set.
    public let description: String?
    /// Retired: not part of the corrected `PublicUserProfileApp` component.
    /// Kept for source compatibility and always `nil` (issue #505).
    public var requestCount: Int? { nil }
    /// Workspace slug the app belongs to, when present.
    public let workspaceSlug: String?
    /// Workspace display name, when present.
    public let workspaceName: String?

    /// Creates a new public app summary instance using the legacy `slug`
    /// label. `requestCount` is accepted but ignored (issue #505).
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
        self.init(
            id: id,
            name: name,
            appSlug: slug,
            iconUrl: iconUrl,
            description: description,
            workspaceSlug: workspaceSlug,
            workspaceName: workspaceName
        )
    }

    /// Creates a new public app summary instance using the corrected
    /// `appSlug` label.
    public init(
        id: String,
        name: String,
        appSlug: String,
        iconUrl: String? = nil,
        description: String? = nil,
        workspaceSlug: String? = nil,
        workspaceName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.appSlug = appSlug
        self.iconUrl = iconUrl
        self.description = description
        self.workspaceSlug = workspaceSlug
        self.workspaceName = workspaceName
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, appSlug, iconUrl, description, workspaceSlug, workspaceName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        // Required on the corrected wire: the phantom `slug` key was never
        // served, so accepting it would let a stale payload decode with an
        // empty slug (#505).
        appSlug = try container.decode(String.self, forKey: .appSlug)
        // All seven keys are required by `PublicUserProfileApp`; nullable
        // values accept an explicit null (issue #505).
        iconUrl = try container.decode(String?.self, forKey: .iconUrl)
        description = try container.decode(String?.self, forKey: .description)
        workspaceSlug = try container.decode(String?.self, forKey: .workspaceSlug)
        workspaceName = try container.decode(String?.self, forKey: .workspaceName)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(appSlug, forKey: .appSlug)
        // Preserve required-nullable keys as explicit nulls on round trip.
        try container.encode(iconUrl, forKey: .iconUrl)
        try container.encode(description, forKey: .description)
        try container.encode(workspaceSlug, forKey: .workspaceSlug)
        try container.encode(workspaceName, forKey: .workspaceName)
    }
}

/// The corrected `PublicUserProfileApp` component served in a profile's
/// `publicApps` array. ``PublicAppSummary`` is the historical name for the
/// same shape (issue #505).
public typealias PublicUserProfileApp = PublicAppSummary
