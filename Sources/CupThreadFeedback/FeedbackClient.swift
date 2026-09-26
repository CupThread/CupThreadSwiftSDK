import Foundation

/// Connection settings for a ``FeedbackClient``.
///
/// Create one configuration per CupThread app and share it across clients.
/// Hosts embedding several CupThread apps should also give each app its own
/// ``UserTokenStore/init(appKey:)`` — the anonymous end-user identity is
/// scoped per app key, so votes, comments, and submissions stay isolated:
///
/// ```swift
/// let configuration = FeedbackClientConfiguration(
///     baseURL: URL(string: "https://api.cupthread.com")!,
///     appKey: "app_xxx"   // from the CupThread developer console
/// )
/// ```
public struct FeedbackClientConfiguration: Equatable, Sendable {
    /// The API root, without a trailing path — normally `https://api.cupthread.com`.
    ///
    /// All endpoints are appended to this URL, e.g. `…/api/v1/feedback`.
    public let baseURL: URL

    /// The app key identifying your app in CupThread (starts with `app_`).
    ///
    /// Sent with most requests and embedded in public endpoint paths such as
    /// `GET /api/v1/public/config/{appKey}`.
    public let appKey: String

    /// The platform value reported with feedback submissions.
    ///
    /// Defaults to ``FeedbackPlatform/current``, which matches the OS the SDK
    /// is running on. Override it when the app reports a custom platform —
    /// e.g. a Mac Catalyst build that should count as `.macos`.
    public let defaultPlatform: FeedbackPlatform

    /// A stable `X-Request-Id` sent with every request, so server logs can
    /// correlate a whole session — e.g. a UUID generated once per app run.
    ///
    /// The server honors ids matching `^[A-Za-z0-9._-]{8,64}$`; anything else
    /// is replaced. When `nil` (the default) the SDK generates a fresh UUID
    /// per request. Every response echoes an `X-Request-Id`, which the SDK
    /// attaches to ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
    /// so users can quote it in support conversations.
    public let requestID: String?

    /// The secret key used to HMAC-SHA256 sign payment-attribute reports
    /// on `PUT /api/v1/public/apps/{appKey}/user`.
    ///
    /// Obtain this secret from the CupThread developer console:
    /// *App Access → App Credentials → SDK signing secret*.
    /// When `nil`, requests reporting payment attributes (`isPaying`, `plan`, `mrr`)
    /// are sent unsigned and will be rejected by the server. Requests without
    /// payment attributes (identity or `currency`-only updates) do not require a secret.
    public let signingSecret: String?

    /// Creates a configuration for a CupThread app.
    /// - Parameters:
    ///   - baseURL: The API root, normally `https://api.cupthread.com`.
    ///   - appKey: Your app's key from the CupThread developer console.
    ///   - defaultPlatform: The platform reported with feedback submissions.
    ///     Defaults to the OS the SDK is running on.
    ///   - requestID: Optional stable `X-Request-Id` sent with every request;
    ///     defaults to a per-request UUID.
    ///   - signingSecret: Optional SDK signing secret for HMAC-SHA256 request
    ///     signing when reporting paying-user attributes (`isPaying`, `plan`, `mrr`).
    public init(
        baseURL: URL,
        appKey: String,
        defaultPlatform: FeedbackPlatform = FeedbackPlatform.current,
        requestID: String? = nil,
        signingSecret: String? = nil
    ) {
        self.baseURL = baseURL
        self.appKey = appKey
        self.defaultPlatform = defaultPlatform
        self.requestID = requestID
        self.signingSecret = signingSecret
    }
}

/// The HTTP client for the CupThread feedback API.
///
/// One client serves every SDK surface — feedback, feature requests, roadmap,
/// and changelog. Create it once with a ``FeedbackClientConfiguration`` and
/// share it freely; the client is `Sendable` and stateless apart from two
/// shared helpers: the search throttle (``SearchRequestThrottle``), which the
/// search surfaces share so sustained typing stays below the API's per-IP
/// search rate limit, and the short-TTL app-config cache
/// (``FeedbackClient/cachedAppConfig()``), which all surfaces share so
/// presenting any number of them costs at most one configuration GET per
/// TTL window.
///
/// ```swift
/// let client = FeedbackClient(
///     configuration: FeedbackClientConfiguration(
///         baseURL: URL(string: "https://api.cupthread.com")!,
///         appKey: "app_xxx"
///     )
/// )
/// ```
///
/// The views (``FeedbackComposerView``, ``FeatureRequestsView``,
/// ``RoadmapBoardView``, ``WhatsNewView``) use the same client, so you can mix
/// ready-made UI with direct calls like ``submit(_:userToken:)``.
public struct FeedbackClient: Sendable {
    /// The configuration this client was created with.
    public let configuration: FeedbackClientConfiguration
    let session: URLSession
    let encoder: JSONEncoder
    let decoder: JSONDecoder
    let overlayPresenter: (any ChangelogOverlayPresenter)?
    /// Shared gate for query-bearing searches; one bucket per client so
    /// ``FeatureRequestsView`` and ``RoadmapBoardView`` spend a single
    /// per-IP budget.
    let searchThrottle: SearchRequestThrottle
    /// App-key-scoped anonymous identity backing every call that omits an
    /// explicit `userToken`. One client ⇒ one identity per CupThread app,
    /// so hosts embedding several apps never bleed identities across them.
    let tokenStore: UserTokenStore
    /// Shared short-TTL cache for the app configuration; every config reader
    /// (theme, surface gating, composer, changelog overlay) goes through it.
    let configStore: AppConfigStore
    /// Optional provider the SDK consults for a Cloudflare Turnstile token on
    /// the human-verification-gated intake calls (feedback and feature-request
    /// submission, upload-session creation). Production intake is gated, so
    /// submissions cannot succeed without a token: hosts with their own
    /// verification flow — or a server-side exemption arrangement — supply it
    /// here. Called once per attempt (including the automatic single retry
    /// after a turnstile rejection), so it can mint a fresh token each time.
    /// When `nil` (the default), gated submissions throw
    /// ``FeedbackClientError/turnstileRequired(message:requestId:)`` after a
    /// single attempt.
    let turnstileTokenProvider: (@Sendable () async -> String?)?
    /// Resolves the signed-in end user's bearer token on demand.
    let authenticationProvider: (@Sendable () async -> String?)?

    /// Creates a client for a CupThread app.
    ///
    /// Some actions are signed-in-only on the server — posting comments on
    /// feature requests requires a Clerk session and fails with
    /// `401 authentication_required` for anonymous callers, as do reading
    /// comments, feature requests, roadmap columns, versions, or changelog
    /// entries and subscribing when the app's console settings disable
    /// anonymous access (`allowAnonymousRoadmap`, `allowAnonymousChangelog`).
    /// Pass an authentication provider that returns the signed-in user's current
    /// bearer token (or `nil` while signed out); the SDK sends it as
    /// `Authorization: Bearer …` on those requests and keeps the anonymous
    /// `X-User-Token` correlation header. Return `nil` when the user is
    /// signed out or the token cannot be refreshed — surfaces then show
    /// their deliberate signed-out state instead of a request that cannot
    /// succeed.
    /// - Parameters:
    ///   - configuration: API root, app key, and default reported platform.
    ///   - session: The URL session requests run in. Override to install a
    ///     custom `URLProtocol` (tests) or custom timeouts; defaults to `.shared`.
    ///   - turnstileTokenProvider: Async closure resolving a Cloudflare
    ///     Turnstile token for gated intake calls, `nil` when none is
    ///     available. Called once per submission attempt, so it can mint a
    ///     fresh token each time.
    ///   - authenticationProvider: Async closure resolving the signed-in
    ///     user's bearer token, `nil` when signed out. Called once per
    ///     authenticated request, so it can refresh an expiring token.
    public init(
        configuration: FeedbackClientConfiguration,
        session: URLSession = .shared,
        turnstileTokenProvider: (@Sendable () async -> String?)? = nil,
        authenticationProvider: (@Sendable () async -> String?)? = nil
    ) {
        self.init(
            configuration: configuration,
            session: session,
            overlayPresenter: nil,
            turnstileTokenProvider: turnstileTokenProvider,
            authenticationProvider: authenticationProvider
        )
    }

    init(
        configuration: FeedbackClientConfiguration,
        session: URLSession = .shared,
        overlayPresenter: (any ChangelogOverlayPresenter)? = nil,
        tokenStore: UserTokenStore? = nil,
        configStore: AppConfigStore? = nil,
        turnstileTokenProvider: (@Sendable () async -> String?)? = nil,
        authenticationProvider: (@Sendable () async -> String?)? = nil
    ) {
        self.configuration = configuration
        self.session = session
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.overlayPresenter = overlayPresenter
        self.authenticationProvider = authenticationProvider
        self.searchThrottle = SearchRequestThrottle()
        self.tokenStore = tokenStore ?? UserTokenStore(appKey: configuration.appKey)
        self.configStore = configStore ?? AppConfigStore(
            lastGood: SdkConfigCache(appKey: configuration.appKey)
        )
        self.turnstileTokenProvider = turnstileTokenProvider
    }

    /// Submits a feedback draft.
    ///
    /// Titles and descriptions are trimmed; empty contact fields, version
    /// strings, and attachment lists are omitted from the payload. Attachments
    /// contributed by the ``uploadAttachment(data:filename:mimeType:userToken:)``
    /// and ``uploadAttachment(fileURL:filename:mimeType:userToken:)`` variants
    /// are sent as `uploadIds` referencing their upload session. The SDK adds
    /// `sdk` (`cupthread-apple/<semver>`), `sdkVersion` (`<semver>`), `platform`,
    /// and `submittedAt` metadata automatically; these reserved keys are
    /// SDK-authored, so draft metadata entries with the same names are replaced
    /// before sending (mirroring the Android SDK's merge where the SDK map
    /// wins), while all other custom metadata is preserved. Submissions then
    /// apply the server's metadata redaction contract locally (credential-looking
    /// keys are redacted, values truncated, oversized payloads shrunk). Every
    /// request also carries the SDK's version in the `X-SDK-Version` header.
    ///
    /// When the client was created with a `turnstileTokenProvider`, its token
    /// is sent as `turnstileToken`. Production intake is gated behind
    /// Cloudflare Turnstile: if the server rejects the submission with the
    /// human-verification gate (HTTP 403), the SDK asks the provider for a
    /// fresh token and retries exactly once before throwing.
    ///
    /// ```swift
    /// var draft = FeedbackDraft.autofilled()
    /// draft.title = "Sync drops edits"
    /// draft.description = "Editing while offline loses my last change."
    /// let result = try await client.submit(draft, userToken: token)
    /// ```
    /// - Parameters:
    ///   - draft: The feedback to send. See ``FeedbackDraft``.
    ///   - userToken: Optional anonymous token (UUID string). When provided it is
    ///     sent as `X-User-Token` so the backend can link the submission to an end-user identity.
    ///     When `userToken` is `nil` and the draft contains attachments with upload IDs,
    ///     the SDK falls back to this client's app-key-scoped store so anonymous flows keep a stable
    ///     identity across session creation and feedback submission.
    /// - Returns: The server's receipt, including the submission id, any warning, and any warning code.
    /// - Throws: ``FeedbackClientError/scanRejected(message:requestId:)`` when an attachment
    ///   referenced in the submission was rejected by server-side content scan (HTTP 422 `scan_rejected`);
    ///   ``FeedbackClientError/submissionQuotaExceeded(message:)`` when the app's
    ///   workspace has reached its monthly submission quota (HTTP 402 `tier_limit_submissions`),
    ///   ``FeedbackClientError/subscriptionInactive(message:)`` when the workspace
    ///   subscription is inactive or canceled (HTTP 402 `subscription_inactive`),
    ///   ``FeedbackClientError/turnstileRequired(message:requestId:)`` when the
    ///   server's Turnstile gate rejects the submission and no fresh token could
    ///   be presented (HTTP 403),
    ///   ``FeedbackClientError/rateLimited`` on HTTP 429,
    ///   ``FeedbackClientError/authenticationRequired`` or
    ///   ``FeedbackClientError/forbidden(message:requestId:)`` when anonymous
    ///   feedback is disabled or the platform is outside the console's
    ///   allow-list (HTTP 401/403),
    ///   ``FeedbackClientError/unexpectedStatus(code:message:requestId:)`` for other
    ///   server rejections (successful submissions accept HTTP 200, 201, and 202), or
    ///   ``FeedbackClientError/invalidResponse`` when the response cannot be interpreted.
    public func submit(
        _ draft: FeedbackDraft,
        userToken: String? = nil
    ) async throws -> FeedbackSubmissionResult {
        let uploadIds = draft.attachments.compactMap(\.uploadId).nilIfEmpty
        let effectiveUserToken = resolvedSubmitUserToken(userToken, hasAttachments: uploadIds != nil)
        let data = try await sendWithTurnstileRetry(accepted: Self.acceptedSubmitStatuses) { token, requestID in
            var request = URLRequest(url: self.configuration.baseURL.appending(path: "/api/v1/feedback"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            self.applyCorrelationHeaders(userToken: effectiveUserToken, requestID: requestID, to: &request)
            request.httpBody = try self.encoder.encode(self.submissionPayload(
                for: draft,
                uploadIds: uploadIds,
                turnstileToken: token
            ))
            return request
        }
        return try decoder.decode(FeedbackSubmissionResult.self, from: data)
    }

    private static let acceptedSubmitStatuses: Set<Int> = [200, 201, 202]

    /// Whether this client can act on behalf of a signed-in end user —
    /// i.e. it was created with an `authenticationProvider`. Signed-in-only
    /// actions (posting comments, or accessing roadmap and changelog surfaces
    /// when anonymous access is disabled) require it; SDK surfaces use this
    /// to show a deliberate signed-out state instead of requests that cannot succeed.
    public var supportsAuthentication: Bool {
        authenticationProvider != nil
    }

    /// Resolves the signed-in identity's bearer token through the
    /// authentication provider and presents it as `Authorization: Bearer …`.
    /// A `nil` or blank provider result (or no provider at all) leaves the
    /// header unset, so the server's `401 authentication_required` response
    /// decides the outcome.
    func applyBearerToken(to request: inout URLRequest) async {
        guard let authenticationProvider else { return }
        if let bearer = await authenticationProvider()?.nilIfEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
    }
}
