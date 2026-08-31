import Foundation

// MARK: - Feature request record (mirrors the server FeatureRequestRecord)

/// A public feature request as returned by `GET /api/v1/feature-requests`.
///
/// Grouping on the roadmap board is driven by `columnSlug`/`columnName`;
/// `status` mirrors the raw server value (historically the column slug) and
/// is kept for display only.
public struct FeatureRequestItem: Codable, Identifiable, Equatable, Sendable {
    /// Stable request id.
    public let id: String
    /// The app the request belongs to.
    public let appId: String
    /// Short summary shown as the card title.
    public let title: String
    /// Full description; may contain inline Markdown.
    public let description: String
    /// Raw server status (historically the column slug); display only.
    public let status: String
    /// Id of the board column the request sits in, when assigned.
    public let columnId: String?
    /// Slug of the board column, when assigned.
    public let columnSlug: String?
    /// Display name of the board column, when assigned.
    public let columnName: String?
    /// Id of the tagged version, when any.
    public let versionId: String?
    /// Display label of the tagged version, when any.
    public let versionLabel: String?
    /// Version the request shipped in, once released.
    public let releasedVersion: String?
    /// Display name of the requester, when given.
    public let requesterName: String?
    /// Whether an admin approved the request; unapproved requests show a
    /// "pending review" badge to their submitter.
    public let approved: Bool
    /// Current total vote count.
    public let voteCount: Int
    /// Whether the user token of the last fetch has voted on this request.
    public let hasVoted: Bool
    /// Whether the request was submitted with the user token of the last fetch.
    public let isOwnRequest: Bool
    /// ISO-8601 creation timestamp as reported by the server.
    public let createdAt: String
    /// ISO-8601 last-update timestamp as reported by the server.
    public let updatedAt: String

    /// Human-readable stage label, preferring the board column name.
    public var stageName: String { columnName ?? status }

    /// Creates a feature request item.
    /// - Parameters:
    ///   - id: Stable request id.
    ///   - appId: The app the request belongs to.
    ///   - title: Short summary.
    ///   - description: Full description.
    ///   - status: Raw server status; display only.
    ///   - columnId: Id of the board column, if assigned.
    ///   - columnSlug: Slug of the board column, if assigned.
    ///   - columnName: Display name of the board column, if assigned.
    ///   - versionId: Id of the tagged version, if any.
    ///   - versionLabel: Label of the tagged version, if any.
    ///   - releasedVersion: Version the request shipped in, if released.
    ///   - requesterName: Requester display name, if given.
    ///   - approved: Whether the request passed admin review.
    ///   - voteCount: Current vote count.
    ///   - hasVoted: Whether the requesting user has voted.
    ///   - isOwnRequest: Whether the requesting user submitted this request.
    ///   - createdAt: ISO-8601 creation timestamp.
    ///   - updatedAt: ISO-8601 last-update timestamp.
    public init(
        id: String,
        appId: String,
        title: String,
        description: String,
        status: String,
        columnId: String? = nil,
        columnSlug: String? = nil,
        columnName: String? = nil,
        versionId: String? = nil,
        versionLabel: String? = nil,
        releasedVersion: String? = nil,
        requesterName: String? = nil,
        approved: Bool,
        voteCount: Int,
        hasVoted: Bool,
        isOwnRequest: Bool,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.appId = appId
        self.title = title
        self.description = description
        self.status = status
        self.columnId = columnId
        self.columnSlug = columnSlug
        self.columnName = columnName
        self.versionId = versionId
        self.versionLabel = versionLabel
        self.releasedVersion = releasedVersion
        self.requesterName = requesterName
        self.approved = approved
        self.voteCount = voteCount
        self.hasVoted = hasVoted
        self.isOwnRequest = isOwnRequest
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func withVoteState(voted: Bool, count: Int) -> FeatureRequestItem {
        FeatureRequestItem(
            id: id,
            appId: appId,
            title: title,
            description: description,
            status: status,
            columnId: columnId,
            columnSlug: columnSlug,
            columnName: columnName,
            versionId: versionId,
            versionLabel: versionLabel,
            releasedVersion: releasedVersion,
            requesterName: requesterName,
            approved: approved,
            voteCount: count,
            hasVoted: voted,
            isOwnRequest: isOwnRequest,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

// MARK: - Submit draft

/// A new feature request as typed by the end user, before submission.
public struct FeatureRequestDraft: Equatable, Sendable {
    /// Short summary; shown as the request's title.
    public var title: String
    /// Full description of the idea or problem.
    public var description: String
    /// Optional display name; empty submits anonymously.
    public var requesterName: String

    /// Creates a draft. All fields default to empty.
    /// - Parameters:
    ///   - title: Short summary.
    ///   - description: Full description.
    ///   - requesterName: Optional display name.
    public init(title: String = "", description: String = "", requesterName: String = "") {
        self.title = title
        self.description = description
        self.requesterName = requesterName
    }
}

// MARK: - Server responses

/// Response to ``FeedbackClient/submitFeatureRequest(_:userToken:)``.
public struct FeatureRequestSubmissionResult: Codable, Equatable, Sendable {
    /// Id of the newly created request.
    public let featureRequestId: String
    /// Whether the request awaits admin approval before becoming public.
    public let pending: Bool
}

/// Response to ``FeedbackClient/toggleVote(featureRequestId:userToken:)``.
public struct VoteResult: Codable, Equatable, Sendable {
    /// The user's vote state after the toggle.
    public let voted: Bool
    /// The request's authoritative vote count after the toggle.
    public let voteCount: Int
}

// MARK: - List response

/// Response to ``FeedbackClient/fetchFeatureRequests(userToken:limit:offset:versionId:query:)``.
public struct ListFeatureRequestsResult: Codable, Sendable {
    /// One page of requests matching the query and filters.
    public let requests: [FeatureRequestItem]
    /// Total number of matching requests, independent of pagination.
    public let total: Int
}
