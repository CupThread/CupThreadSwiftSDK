import Foundation

// MARK: - Public app config (GET /api/v1/public/config/{appKey})

/// The app's public configuration, mirrored from `PublicAppConfig` in `@cupthread/shared`.
public struct PublicAppConfig: Codable, Equatable, Sendable {
    public let appId: String
    public let appKey: String
    public let slug: String
    public let name: String
    public let storeUrl: URL?
    public let storeKind: String?
    public let iconUrl: URL?
    public let allowPublic: Bool
    public let allowedPlatforms: [FeedbackPlatform]
    public let maxAttachmentBytes: Int
    public let allowAnonymousRoadmap: Bool
    public let allowAnonymousVote: Bool
    public let allowAnonymousFeedback: Bool
    public let allowAnonymousChangelog: Bool
    public let sdk: SdkAppearance

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appId = try container.decode(String.self, forKey: .appId)
        appKey = try container.decode(String.self, forKey: .appKey)
        slug = try container.decode(String.self, forKey: .slug)
        name = try container.decode(String.self, forKey: .name)
        storeUrl = try container.decodeIfPresent(URL.self, forKey: .storeUrl)
        storeKind = try container.decodeIfPresent(String.self, forKey: .storeKind)
        iconUrl = try container.decodeIfPresent(URL.self, forKey: .iconUrl)
        allowPublic = try container.decodeIfPresent(Bool.self, forKey: .allowPublic) ?? true
        allowedPlatforms = try container.decodeIfPresent([FeedbackPlatform].self, forKey: .allowedPlatforms) ?? []
        maxAttachmentBytes = try container.decodeIfPresent(Int.self, forKey: .maxAttachmentBytes) ?? 20_000_000
        allowAnonymousRoadmap = try container.decodeIfPresent(Bool.self, forKey: .allowAnonymousRoadmap) ?? true
        allowAnonymousVote = try container.decodeIfPresent(Bool.self, forKey: .allowAnonymousVote) ?? true
        allowAnonymousFeedback = try container.decodeIfPresent(Bool.self, forKey: .allowAnonymousFeedback) ?? true
        allowAnonymousChangelog = try container.decodeIfPresent(Bool.self, forKey: .allowAnonymousChangelog) ?? true
        sdk = try container.decodeIfPresent(SdkAppearance.self, forKey: .sdk) ?? .defaults
    }
}

// MARK: - Board columns (GET /api/v1/public/columns/{appKey})

public struct BoardColumn: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case pendingReview = "pending_review"
        case normal
        case done
    }

    public let id: String
    public let appId: String
    public let name: String
    public let slug: String
    public let position: Int
    public let isVisible: Bool
    public let isSystem: Bool
    public let kind: Kind
    public let createdAt: String
    public let updatedAt: String
}

struct ListColumnsResponse: Codable, Sendable {
    let columns: [BoardColumn]
}

// MARK: - App versions (GET /api/v1/public/versions/{appKey})

public struct AppVersion: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let appId: String
    public let label: String
    public let position: Int
    public let released: Bool
    public let releasedAt: String?
    public let description: String?
    public let createdAt: String
    public let updatedAt: String
}

struct ListVersionsResponse: Codable, Sendable {
    let versions: [AppVersion]
}

// MARK: - Client extensions

extension FeedbackClient {

    /// Fetches the app's public configuration (visibility flags, allowed platforms, attachment limit).
    public func fetchAppConfig() async throws -> PublicAppConfig {
        try await get("/api/v1/public/config/\(configuration.appKey)")
    }

    /// Fetches the visible roadmap board columns, ordered by position.
    public func fetchColumns() async throws -> [BoardColumn] {
        let response: ListColumnsResponse = try await get("/api/v1/public/columns/\(configuration.appKey)")
        return response.columns.sorted { $0.position < $1.position }
    }

    /// Fetches the app's versions, ordered by position.
    public func fetchVersions() async throws -> [AppVersion] {
        let response: ListVersionsResponse = try await get("/api/v1/public/versions/\(configuration.appKey)")
        return response.versions.sorted { $0.position < $1.position }
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: configuration.baseURL.appending(path: path))
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        if httpResponse.statusCode != 200 {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw FeedbackClientError.unexpectedStatus(code: httpResponse.statusCode, message: message)
        }
        return try decoder.decode(T.self, from: data)
    }
}
