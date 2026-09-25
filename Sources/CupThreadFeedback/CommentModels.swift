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
    /// App-scoped pseudonymous user identifier of the comment author (e.g.
    /// `u_ab12cd34`), when given. Stable within one app only — never assume
    /// a `user_` prefix or compare it across apps.
    public let authorClerkId: String?
    /// The comment body text.
    public let body: String
    /// Id of the parent comment this is a reply to, when applicable.
    public let parentId: String?
    /// App-scoped pseudonymous identifier of the author being replied to,
    /// when applicable. Same app-scoping caveat as ``authorClerkId``.
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
///
/// Only the body and reply target reach the server: comment creation is
/// signed-in-only, the author display name and avatar always resolve
/// server-side from the signed-in profile, and the reply author's identity
/// is derived from the parent comment. The `authorName`, `authorEmail`,
/// `authorAvatarUrl`, and `replyToClerkId` fields remain for draft-building
/// compatibility but are not transmitted.
public struct CommentDraft: Equatable, Sendable {
    /// The comment body text.
    public var body: String
    /// Optional display name. Not transmitted — the server resolves the
    /// author's name from the signed-in profile.
    public var authorName: String
    /// Optional contact email. Not transmitted.
    public var authorEmail: String
    /// Optional avatar URL for the comment author. Not transmitted — the
    /// server resolves the avatar from the signed-in profile.
    public var authorAvatarUrl: String
    /// Id of the parent comment this is a reply to, when replying.
    public var parentId: String?
    /// App-scoped pseudonymous identifier of the author being replied to
    /// (e.g. `u_ab12cd34`). Not transmitted — the server derives reply
    /// identity from `parentId`.
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

    /// Whether the draft holds a typed comment body.
    ///
    /// Reply-target metadata (`parentId` and friends) is set by tapping the
    /// reply action, not by typing, so it does not count as content worth a
    /// discard confirmation on its own.
    public var hasContent: Bool {
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Server responses

/// One page of `GET /api/v1/feature-requests/{id}/comments`.
///
/// The endpoint pages oldest-first with an opaque keyset cursor over
/// `(createdAt, id)`. Pass ``nextCursor`` back as the `cursor` parameter of
/// ``FeedbackClient/fetchComments(featureRequestId:limit:cursor:)`` to fetch
/// the following page. ``total`` is the visible thread size — hidden and
/// deleted comments are excluded — and is not the length of ``comments``
/// on this page. Bodies published before pagination shipped (no `total` /
/// `hasMore` / `nextCursor` keys) decode as a single complete page.
public struct ListCommentsResult: Decodable, Equatable, Sendable {
    /// The page's comments, oldest first.
    public let comments: [FeatureRequestComment]
    /// Visible thread size. Hidden and deleted comments are excluded, so
    /// this is independent of how many rows ``comments`` holds. `0` when
    /// the server omits the field.
    public let total: Int
    /// Whether another page exists beyond this one.
    public let hasMore: Bool
    /// Opaque keyset cursor for the next page; `nil` on the last page.
    public let nextCursor: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        comments = try container.decode([FeatureRequestComment].self, forKey: .comments)
        // Pagination metadata is additive: responses predating it decode as
        // a complete page (matching the server's former single-payload shape).
        total = try container.decodeIfPresent(Int.self, forKey: .total) ?? 0
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    }

    init(
        comments: [FeatureRequestComment],
        total: Int = 0,
        hasMore: Bool = false,
        nextCursor: String? = nil
    ) {
        self.comments = comments
        self.total = total
        self.hasMore = hasMore
        self.nextCursor = nextCursor
    }

    private enum CodingKeys: String, CodingKey {
        case comments, total, hasMore, nextCursor
    }
}

// MARK: - Comment display model

/// Presentation representation of a comment row, resolving moderation state.
public struct CommentDisplayModel: Equatable, Identifiable, Sendable {
    /// The unique comment id.
    public let id: String
    /// Whether the comment has been removed by a moderator.
    public let isModerated: Bool
    /// The body text to display (or moderation notice).
    public let displayBody: String
    /// The author display name, or nil if redacted due to moderation.
    public let authorName: String?
    /// Avatar URL, or nil if redacted due to moderation.
    public let authorAvatarUrl: String?
    /// App-scoped pseudonymous user id for profile navigation (e.g.
    /// `u_ab12cd34`), or nil if redacted.
    public let authorClerkId: String?
    /// Whether users can reply to this comment.
    public let canReply: Bool
    /// Whether users can tap through to the author's profile.
    public let canOpenAuthorProfile: Bool
    /// Display name of the author being replied to, when applicable.
    public let replyToAuthorName: String?
    /// App-scoped pseudonymous id of the author being replied to, when applicable.
    public let replyToClerkId: String?
    /// Parsed creation date.
    public let createdAtDate: Date?

    /// Creates a display model from a comment.
    public init(comment: FeatureRequestComment) {
        self.id = comment.id
        self.isModerated = comment.isModerated
        self.createdAtDate = comment.createdAtDate
        self.replyToAuthorName = comment.replyToAuthorName
        self.replyToClerkId = comment.isModerated ? nil : comment.replyToClerkId

        if comment.isModerated {
            self.displayBody = CupThreadStrings.tr("cupthread.comments.removed_by_moderator")
            self.authorName = nil
            self.authorAvatarUrl = nil
            self.authorClerkId = nil
            self.canReply = false
            self.canOpenAuthorProfile = false
        } else {
            self.displayBody = comment.body
            self.authorName = comment.authorName ?? CupThreadStrings.tr("cupthread.features.anonymous")
            self.authorAvatarUrl = comment.authorAvatarUrl
            self.authorClerkId = comment.authorClerkId
            self.canReply = true
            self.canOpenAuthorProfile = comment.authorClerkId != nil
        }
    }
}

// MARK: - Comment helpers

extension FeatureRequestComment {
    /// Whether the comment has been hidden by a moderator.
    public var isModerated: Bool {
        isHidden == true
    }

    /// Presentation model for rendering this comment in the UI.
    public var displayModel: CommentDisplayModel {
        CommentDisplayModel(comment: self)
    }

    /// Parsed `createdAt`, accepting plain and fractional-second ISO-8601.
    public var createdAtDate: Date? {
        if let date = try? Date(createdAt, strategy: Self.fractionalISO) {
            return date
        }
        return try? Date(createdAt, strategy: .iso8601)
    }

    private static let fractionalISO = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}
