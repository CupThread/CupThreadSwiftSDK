import Foundation

// MARK: - Public app config (GET /api/v1/public/config/{appKey})

/// The app's public configuration, mirrored from `PublicAppConfig` in `@cupthread/shared`.
///
/// Returned by ``FeedbackClient/fetchAppConfig()``. Most fields mirror
/// console settings; the `allowAnonymous*` flags describe what end users may
/// do without signing in, and ``sdk`` carries the theme/feature/overlay
/// configuration the native SDK applies.
public struct PublicAppConfig: Codable, Equatable, Sendable {
    /// CupThread's internal id for the app.
    public let appId: String
    /// The app key the config was fetched with.
    public let appKey: String
    /// URL-safe slug used in CupThread web links.
    public let slug: String
    /// The app's display name.
    public let name: String
    /// App Store or download page URL, when configured.
    public let storeUrl: URL?
    /// Kind of store behind `storeUrl` (e.g. `"app_store"`), when configured.
    public let storeKind: String?
    /// The app's icon, when uploaded to the console.
    public let iconUrl: URL?
    /// Whether the app's public pages (roadmap, changelog) are visible at all.
    public let allowPublic: Bool
    /// Platforms the console allows feedback from; empty means unrestricted.
    public let allowedPlatforms: [FeedbackPlatform]
    /// Largest accepted attachment upload in bytes; defaults to 20 MB.
    public let maxAttachmentBytes: Int
    /// Whether signed-out users may browse the roadmap board.
    public let allowAnonymousRoadmap: Bool
    /// Whether signed-out users may vote on feature requests.
    public let allowAnonymousVote: Bool
    /// Whether signed-out users may submit feedback.
    public let allowAnonymousFeedback: Bool
    /// Whether signed-out users may read the changelog. `false` makes
    /// ``FeedbackClient/fetchChangelog()`` throw
    /// ``FeedbackClientError/authenticationRequired``.
    public let allowAnonymousChangelog: Bool
    /// Theme, feature flags, and overlay copy configured in the console.
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

/// A roadmap board column, as configured in the CupThread console.
///
/// Returned by ``FeedbackClient/fetchColumns()``; ``RoadmapBoardView`` groups
/// feature requests by these columns.
public struct BoardColumn: Codable, Equatable, Identifiable, Sendable {
    /// The column's role on the board.
    public enum Kind: String, Codable, Sendable {
        /// System column for requests awaiting admin approval.
        case pendingReview = "pending_review"
        /// A regular, admin-created column.
        case normal
        /// System column for shipped requests.
        case done
    }

    /// Stable id used for grouping and selection.
    public let id: String
    /// The app the column belongs to.
    public let appId: String
    /// Display name shown as the column header.
    public let name: String
    /// URL-safe identifier; `StageStyle` heuristics also peek at it.
    public let slug: String
    /// Sort order within the board, lowest first.
    public let position: Int
    /// Whether the console currently shows this column publicly.
    public let isVisible: Bool
    /// Whether the column is one of the console-managed system columns.
    public let isSystem: Bool
    /// The column's role on the board.
    public let kind: Kind
    /// ISO-8601 creation timestamp as reported by the server.
    public let createdAt: String
    /// ISO-8601 last-update timestamp as reported by the server.
    public let updatedAt: String
}

struct ListColumnsResponse: Codable, Sendable {
    let columns: [BoardColumn]
}

// MARK: - App versions (GET /api/v1/public/versions/{appKey})

/// A named release (or planned release) of the app.
///
/// Returned by ``FeedbackClient/fetchVersions()``;
/// ``FeatureRequestsView`` uses versions as a filter, and requests carry a
/// matching `versionId`/`versionLabel` pair when they are tagged.
public struct AppVersion: Codable, Equatable, Identifiable, Sendable {
    /// Stable id used as the filter value.
    public let id: String
    /// The app the version belongs to.
    public let appId: String
    /// Display label, e.g. `"2.1"`.
    public let label: String
    /// Sort order within the version list, lowest first.
    public let position: Int
    /// Whether the version has shipped.
    public let released: Bool
    /// Release date as reported by the server, when released.
    public let releasedAt: String?
    /// Release note copy, when written.
    public let description: String?
    /// ISO-8601 creation timestamp as reported by the server.
    public let createdAt: String
    /// ISO-8601 last-update timestamp as reported by the server.
    public let updatedAt: String
}

struct ListVersionsResponse: Codable, Sendable {
    let versions: [AppVersion]
}

// MARK: - Client extensions

extension FeedbackClient {

    /// Fetches the app's public configuration (visibility flags, allowed platforms, attachment limit).
    ///
    /// This is also the request that carries the ``SdkAppearance`` (theme,
    /// feature flags, overlay copy) applied by ``CupThreadTheme`` and every
    /// SDK view.
    /// - Returns: The app's current public configuration.
    /// - Throws: ``FeedbackClientError/unexpectedStatus(code:message:)`` — with
    ///   status 404 for an unknown app key — or
    ///   ``FeedbackClientError/invalidResponse``.
    public func fetchAppConfig() async throws -> PublicAppConfig {
        try await get("/api/v1/public/config/\(configuration.appKey)")
    }

    /// Fetches the visible roadmap board columns, ordered by position.
    /// - Returns: The board's visible columns, sorted by ``BoardColumn/position``.
    /// - Throws: ``FeedbackClientError/unexpectedStatus(code:message:)`` or
    ///   ``FeedbackClientError/invalidResponse``.
    public func fetchColumns() async throws -> [BoardColumn] {
        let response: ListColumnsResponse = try await get("/api/v1/public/columns/\(configuration.appKey)")
        return response.columns.sorted { $0.position < $1.position }
    }

    /// Fetches the app's versions, ordered by position.
    /// - Returns: Released and planned versions, sorted by ``AppVersion/position``.
    /// - Throws: ``FeedbackClientError/unexpectedStatus(code:message:)`` or
    ///   ``FeedbackClientError/invalidResponse``.
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
