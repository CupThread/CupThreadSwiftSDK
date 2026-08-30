import Foundation

// MARK: - Feature request record (mirrors the server FeatureRequestRecord)

/// A public feature request as returned by `GET /api/v1/feature-requests`.
///
/// Grouping on the roadmap board is driven by `columnSlug`/`columnName`;
/// `status` mirrors the raw server value (historically the column slug) and
/// is kept for display only.
public struct FeatureRequestItem: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let appId: String
    public let title: String
    public let description: String
    public let status: String
    public let columnId: String?
    public let columnSlug: String?
    public let columnName: String?
    public let versionId: String?
    public let versionLabel: String?
    public let releasedVersion: String?
    public let requesterName: String?
    public let approved: Bool
    public let voteCount: Int
    public let hasVoted: Bool
    public let isOwnRequest: Bool
    public let createdAt: String
    public let updatedAt: String

    /// Human-readable stage label, preferring the board column name.
    public var stageName: String { columnName ?? status }

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

public struct FeatureRequestDraft: Equatable, Sendable {
    public var title: String
    public var description: String
    public var requesterName: String

    public init(title: String = "", description: String = "", requesterName: String = "") {
        self.title = title
        self.description = description
        self.requesterName = requesterName
    }
}

// MARK: - Server responses

public struct FeatureRequestSubmissionResult: Codable, Equatable, Sendable {
    public let featureRequestId: String
    public let pending: Bool
}

public struct VoteResult: Codable, Equatable, Sendable {
    public let voted: Bool
    public let voteCount: Int
}

// MARK: - List response

public struct ListFeatureRequestsResult: Codable, Sendable {
    public let requests: [FeatureRequestItem]
    public let total: Int
}
