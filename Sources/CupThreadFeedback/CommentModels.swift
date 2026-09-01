import Foundation

// MARK: - Comment on a feature request

/// A public comment on a feature request, as returned by
/// `GET /api/v1/feature-requests/{id}/comments`.
///
/// Comments form a flat list; replies reference a parent via ``parentId``
/// and carry the mentioned author's name in ``replyToAuthorName``.
public struct FeatureRequestComment: Codable, Identifiable, Equatable, Sendable {
    /// Stable comment id.
    public let id: String
    /// The feature request this comment belongs to.
    public let featureRequestId: String
    /// Display name of the comment author, when given.
    public let authorName: String?
    /// Email of the comment author, when given.
    public let authorEmail: String?
    /// Avatar URL of the comment author, when given.
    public let authorAvatarUrl: String?
    /// Clerk user id of the comment author, when given.
    public let authorClerkId: String?
    /// The comment body text.
    public let body: String
    /// Id of the parent comment this is a reply to, when applicable.
    public let parentId: String?
    /// Clerk user id of the author being replied to, when applicable.
    public let replyToClerkId: String?
    /// Display name of the author being replied to, when applicable.
    public let replyToAuthorName: String?
    /// Whether the comment has been hidden by a moderator.
    public let isHidden: Bool?
    /// ISO-8601 creation timestamp as reported by the server.
    public let createdAt: String

    /// Creates a comment item.
    public init(
        id: String,
        featureRequestId: String,
        authorName: String? = nil,
        authorEmail: String? = nil,
        authorAvatarUrl: String? = nil,
        authorClerkId: String? = nil,
        body: String,
        parentId: String? = nil,
        replyToClerkId: String? = nil,
        replyToAuthorName: String? = nil,
        isHidden: Bool? = nil,
        createdAt: String
    ) {
        self.id = id
        self.featureRequestId = featureRequestId
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authorAvatarUrl = authorAvatarUrl
        self.authorClerkId = authorClerkId
        self.body = body
        self.parentId = parentId
        self.replyToClerkId = replyToClerkId
        self.replyToAuthorName = replyToAuthorName
        self.isHidden = isHidden
        self.createdAt = createdAt
    }
}

// MARK: - Comment draft

/// A new comment as typed by the end user, before submission.
public struct CommentDraft: Equatable, Sendable {
    /// The comment body text.
    public var body: String
    /// Optional display name; empty submits anonymously.
    public var authorName: String
    /// Optional contact email.
    public var authorEmail: String
    /// Optional avatar URL for the comment author.
    public var authorAvatarUrl: String
    /// Id of the parent comment this is a reply to, when replying.
    public var parentId: String?
    /// Clerk user id of the author being replied to, when replying.
    public var replyToClerkId: String?
    /// Display name of the author being replied to, when replying.
    public var replyToAuthorName: String?

    /// Creates a draft. All fields default to empty.
    public init(
        body: String = "",
        authorName: String = "",
        authorEmail: String = "",
        authorAvatarUrl: String = "",
        parentId: String? = nil,
        replyToClerkId: String? = nil,
        replyToAuthorName: String? = nil
    ) {
        self.body = body
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authorAvatarUrl = authorAvatarUrl
        self.parentId = parentId
        self.replyToClerkId = replyToClerkId
        self.replyToAuthorName = replyToAuthorName
    }
}

// MARK: - Server responses

/// Response wrapper for `GET /api/v1/feature-requests/{id}/comments`.
struct ListCommentsResponse: Codable, Sendable {
    let comments: [FeatureRequestComment]
}

// MARK: - Date helpers

extension FeatureRequestComment {
    /// Parsed `createdAt`, accepting plain and fractional-second ISO-8601.
    var createdAtDate: Date? {
        if let date = try? Date(createdAt, strategy: Self.fractionalISO) {
            return date
        }
        return try? Date(createdAt, strategy: .iso8601)
    }

    private static let fractionalISO = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}
