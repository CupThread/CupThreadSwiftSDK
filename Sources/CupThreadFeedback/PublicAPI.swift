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
    /// The app's public website URL, when configured (Web / Universal apps).
    /// Native SDK surfaces do not render it; mirrored for schema completeness.
    public let websiteUrl: URL?
    /// Whether the public web portal hides CupThread branding (logo/title).
    /// Native SDK surfaces are unaffected; mirrored for schema completeness.
    public let hideSiteBranding: Bool
    /// Whether the app's public pages (roadmap, changelog) are visible at all.
    ///
    /// Since the September 2026 API sync, the config endpoints answer a
    /// private app with `404` — the same body as an unknown app key — instead
    /// of a `200` payload with `allowPublic: false`, so a successfully decoded
    /// ``PublicAppConfig`` always carries `true`. The field is kept for schema
    /// parity with the server's `PublicAppConfig`.
    public let allowPublic: Bool
    /// Platforms the console allows feedback from; empty means unrestricted.
    ///
    /// Known platforms are projected to ``FeedbackPlatform``; unknown platform
    /// values from newer console versions are accessible via ``allowedPlatformValues``.
    public let allowedPlatforms: [FeedbackPlatform]
    /// Raw platform strings as reported by the console, preserving any platforms unknown to this SDK version.
    public let allowedPlatformValues: [String]
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

    private enum CodingKeys: String, CodingKey {
        case appId
        case appKey
        case slug
        case name
        case storeUrl
        case storeKind
        case iconUrl
        case websiteUrl
        case hideSiteBranding
        case allowPublic
        case allowedPlatforms
        case maxAttachmentBytes
        case allowAnonymousRoadmap
        case allowAnonymousVote
        case allowAnonymousFeedback
        case allowAnonymousChangelog
        case sdk
    }

    public init(
        appId: String,
        appKey: String,
        slug: String,
        name: String,
        storeUrl: URL? = nil,
        storeKind: String? = nil,
        iconUrl: URL? = nil,
        websiteUrl: URL? = nil,
        hideSiteBranding: Bool = false,
        allowPublic: Bool = true,
        allowedPlatforms: [FeedbackPlatform]? = nil,
        allowedPlatformValues: [String] = [],
        maxAttachmentBytes: Int = 20_000_000,
        allowAnonymousRoadmap: Bool = true,
        allowAnonymousVote: Bool = true,
        allowAnonymousFeedback: Bool = true,
        allowAnonymousChangelog: Bool = true,
        sdk: SdkAppearance = .defaults
    ) {
        self.appId = appId
        self.appKey = appKey
        self.slug = slug
        self.name = name
        self.storeUrl = storeUrl
        self.storeKind = storeKind
        self.iconUrl = iconUrl
        self.websiteUrl = websiteUrl
        self.hideSiteBranding = hideSiteBranding
        self.allowPublic = allowPublic
        if let allowedPlatforms {
            self.allowedPlatforms = allowedPlatforms
            self.allowedPlatformValues = allowedPlatformValues.isEmpty ? allowedPlatforms.map(\.rawValue) : allowedPlatformValues
        } else {
            self.allowedPlatformValues = allowedPlatformValues
            self.allowedPlatforms = allowedPlatformValues.compactMap { FeedbackPlatform(rawValue: $0) }
        }
        self.maxAttachmentBytes = maxAttachmentBytes
        self.allowAnonymousRoadmap = allowAnonymousRoadmap
        self.allowAnonymousVote = allowAnonymousVote
        self.allowAnonymousFeedback = allowAnonymousFeedback
        self.allowAnonymousChangelog = allowAnonymousChangelog
        self.sdk = sdk
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appId = try container.decode(String.self, forKey: .appId)
        appKey = try container.decode(String.self, forKey: .appKey)
        slug = try container.decode(String.self, forKey: .slug)
        name = try container.decode(String.self, forKey: .name)
        storeUrl = try container.decodeIfPresent(URL.self, forKey: .storeUrl)
        storeKind = try container.decodeIfPresent(String.self, forKey: .storeKind)
        iconUrl = try container.decodeIfPresent(URL.self, forKey: .iconUrl)
        websiteUrl = try container.decodeIfPresent(URL.self, forKey: .websiteUrl)
        hideSiteBranding = try container.decodeIfPresent(Bool.self, forKey: .hideSiteBranding) ?? false
        allowPublic = try container.decodeIfPresent(Bool.self, forKey: .allowPublic) ?? true
        let platformStrings = try container.decodeIfPresent([String].self, forKey: .allowedPlatforms) ?? []
        allowedPlatformValues = platformStrings
        allowedPlatforms = platformStrings.compactMap { FeedbackPlatform(rawValue: $0) }
        maxAttachmentBytes = try container.decodeIfPresent(Int.self, forKey: .maxAttachmentBytes) ?? 20_000_000
        allowAnonymousRoadmap = try container.decodeIfPresent(Bool.self, forKey: .allowAnonymousRoadmap) ?? true
        allowAnonymousVote = try container.decodeIfPresent(Bool.self, forKey: .allowAnonymousVote) ?? true
        allowAnonymousFeedback = try container.decodeIfPresent(Bool.self, forKey: .allowAnonymousFeedback) ?? true
        allowAnonymousChangelog = try container.decodeIfPresent(Bool.self, forKey: .allowAnonymousChangelog) ?? true
        sdk = try container.decodeIfPresent(SdkAppearance.self, forKey: .sdk) ?? .defaults
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(appId, forKey: .appId)
        try container.encode(appKey, forKey: .appKey)
        try container.encode(slug, forKey: .slug)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(storeUrl, forKey: .storeUrl)
        try container.encodeIfPresent(storeKind, forKey: .storeKind)
        try container.encodeIfPresent(iconUrl, forKey: .iconUrl)
        try container.encodeIfPresent(websiteUrl, forKey: .websiteUrl)
        try container.encode(hideSiteBranding, forKey: .hideSiteBranding)
        try container.encode(allowPublic, forKey: .allowPublic)
        try container.encode(allowedPlatformValues, forKey: .allowedPlatforms)
        try container.encode(maxAttachmentBytes, forKey: .maxAttachmentBytes)
        try container.encode(allowAnonymousRoadmap, forKey: .allowAnonymousRoadmap)
        try container.encode(allowAnonymousVote, forKey: .allowAnonymousVote)
        try container.encode(allowAnonymousFeedback, forKey: .allowAnonymousFeedback)
        try container.encode(allowAnonymousChangelog, forKey: .allowAnonymousChangelog)
        try container.encode(sdk, forKey: .sdk)
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

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            self = Kind(rawValue: raw) ?? .normal
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
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
    /// SDK view. This call always hits the network; use
    /// ``FeedbackClient/cachedAppConfig()`` to read through the shared
    /// short-TTL cache instead.
    /// - Returns: The app's current public configuration.
    /// - Throws: ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
    ///   — with status 404 for an unknown app key or for a private
    ///   (non-public) app, which the API answers identically with
    ///   `"App not found"` — or ``FeedbackClientError/invalidResponse``.
    public func fetchAppConfig() async throws -> PublicAppConfig {
        try await get("/api/v1/public/config/\(configuration.appKey)")
    }

    /// Fetches the app's public configuration through the client's shared
    /// short-TTL cache.
    ///
    /// Equivalent to ``FeedbackClient/fetchAppConfig()``, except that
    /// concurrent callers coalesce into a single request and reads within the
    /// TTL window reuse the last response. The SDK's own surfaces resolve
    /// their console configuration through this method — ``CupThreadTheme``,
    /// per-surface gating, the feedback composer's attachment limit, and the
    /// changelog overlay — so presenting any number of surfaces costs at most
    /// one configuration GET per window per client. The response is also
    /// written to the last-good on-disk cache, and a failed refresh throws
    /// the same errors as ``FeedbackClient/fetchAppConfig()``.
    /// - Returns: The app's current public configuration (fresh, or cached
    ///   within the TTL window).
    /// - Throws: The same errors as ``FeedbackClient/fetchAppConfig()`` when
    ///   the window has expired and the refresh fails.
    public func cachedAppConfig() async throws -> PublicAppConfig {
        try await configStore.config { [self] in try await fetchAppConfig() }
    }

    /// Fetches the visible roadmap board columns, ordered by position.
    /// - Returns: The board's visible columns, sorted by ``BoardColumn/position``.
    /// - Throws: ``FeedbackClientError/authenticationRequired`` or
    ///   ``FeedbackClientError/forbidden(message:requestId:)`` when anonymous
    ///   roadmap access is disabled for the app (HTTP 401/403),
    ///   ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
    ///   or ``FeedbackClientError/invalidResponse``.
    public func fetchColumns() async throws -> [BoardColumn] {
        let response: ListColumnsResponse = try await get(
            "/api/v1/public/columns/\(configuration.appKey)",
            mapsPermissionErrors: true
        )
        return response.columns.sorted { $0.position < $1.position }
    }

    /// Fetches the app's versions, ordered by position.
    /// - Returns: Released and planned versions, sorted by ``AppVersion/position``.
    /// - Throws: ``FeedbackClientError/authenticationRequired`` when anonymous
    ///   access is disabled for the app (HTTP 401 `authentication_required`),
    ///   ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
    ///   or ``FeedbackClientError/invalidResponse``.
    public func fetchVersions() async throws -> [AppVersion] {
        let response: ListVersionsResponse = try await get("/api/v1/public/versions/\(configuration.appKey)")
        return response.versions.sorted { $0.position < $1.position }
    }

    private func get<T: Decodable>(
        _ path: String,
        mapsPermissionErrors: Bool = false
    ) async throws -> T {
        var request = URLRequest(url: configuration.baseURL.appending(path: path))
        request.httpMethod = "GET"
        applyCorrelationHeaders(userToken: nil, requestID: nextRequestID(), to: &request)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        try validateResponse(
            httpResponse,
            data: data,
            accepted: [200],
            mapsPermissionErrors: mapsPermissionErrors
        )
        return try decoder.decode(T.self, from: data)
    }
}

// MARK: - Permission gating predicates (issue #34)

public extension PublicAppConfig {
    /// Whether an anonymous SDK user may browse the roadmap board.
    ///
    /// Combines ``allowPublic`` (the public pages are hidden entirely) with
    /// ``allowAnonymousRoadmap``. Client gating is UX preflight — the server
    /// stays authoritative.
    var allowsAnonymousRoadmap: Bool {
        allowPublic && allowAnonymousRoadmap
    }

    /// Whether an anonymous SDK user may vote on feature requests
    /// (console switch `allowAnonymousVote`).
    var allowsAnonymousVote: Bool {
        allowAnonymousVote
    }

    /// Whether an anonymous SDK user may submit feedback or feature requests
    /// (console switch `allowAnonymousFeedback`).
    var allowsAnonymousFeedback: Bool {
        allowAnonymousFeedback
    }

    /// Whether an anonymous SDK user may read the changelog
    /// (console switch `allowAnonymousChangelog`).
    var allowsAnonymousChangelog: Bool {
        allowAnonymousChangelog
    }

    /// Whether submissions reported from `platform` pass the console's
    /// platform allow-list. An empty allow-list means unrestricted.
    /// - Parameter platform: The platform a submission would report.
    /// - Returns: `false` only when the allow-list is non-empty and omits
    ///   `platform`. A raw list whose platforms are all unknown to this SDK
    ///   version counts as non-empty, so the gate stays closed — matching
    ///   the server, which would reject the submission.
    func allows(platform: FeedbackPlatform) -> Bool {
        if allowedPlatformValues.isEmpty {
            return true
        }
        return allowedPlatforms.contains(platform)
    }
}
