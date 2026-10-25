// swiftlint:disable file_length
// One client per file: the session-level contracts (redirect policy, cookie
// isolation) are documented beside the code that enforces them, the same
// policy the other oversized files follow (.swiftlint.yml).
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
    /// `GET /api/v1/public/config/{appKey}`. Surrounding whitespace is
    /// trimmed when the configuration is created (SEC-22), and every request
    /// validates the value against `^[A-Za-z0-9_.-]{1,64}$` before dispatch —
    /// a key that violates the grammar (blank, path separators, traversal
    /// sequences, control characters) throws
    /// ``FeedbackClientError/invalidConfiguration(message:)`` instead of
    /// reaching the network.
    public let appKey: String

    /// The platform value reported with feedback submissions.
    ///
    /// Defaults to ``FeedbackPlatform/current``, which reports `macos` on
    /// macOS and `ios` everywhere else — visionOS and tvOS are iOS-family
    /// builds and report `ios`. Override it when the app should report a
    /// different value — e.g. reporting `ios` from a Mac Catalyst build
    /// (which defaults to `macos`).
    public let defaultPlatform: FeedbackPlatform

    /// A stable `X-Request-Id` sent with every request, so server logs can
    /// correlate a whole session — e.g. a UUID generated once per app run.
    ///
    /// The server honors ids matching `^[A-Za-z0-9._-]{8,64}$`; anything else
    /// is replaced. When `nil` (the default) the SDK generates a fresh UUID
    /// per request. Every response echoes an `X-Request-Id`, which the SDK
    /// attaches to ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
    /// so users can quote it in support conversations — but only after the
    /// echo is validated against the same grammar, so header text injected
    /// by gateways or proxies never reaches user-facing error copy (SEC-12).
    public let requestID: String?

    /// The secret key used to HMAC-SHA256 sign payment-attribute reports
    /// on `PUT /api/v1/public/apps/{appKey}/user`.
    ///
    /// Obtain this secret from the CupThread developer console:
    /// *App Access → App Credentials → SDK signing secret*.
    /// When `nil`, requests reporting payment attributes (`isPaying`, `plan`, `mrr`, `currency`)
    /// are sent unsigned and will be rejected by the server. Requests without
    /// payment attributes (identity-only updates) do not require a secret.
    ///
    /// > Warning: An embedded signing secret is **not tamper-resistant**.
    /// Anyone who installs the app can extract it from the binary and forge
    /// verified payment attributes (`isPaying`, `plan`, `mrr`, `currency`) for
    /// arbitrary end users, poisoning revenue-weighted triage. Prefer
    /// backend-delegated signing — hold the secret on your own server and
    /// install a `userAttributesSigner` provider on ``FeedbackClient`` (SEC-19).
    /// Reserve the embedded secret for internal, debug, or otherwise trusted
    /// builds.
    public let signingSecret: String?

    /// The hosted Turnstile challenge page the in-SDK human-verification
    /// sheet loads when an intake call is rejected by the API's gate and no
    /// `turnstileTokenProvider` is installed.
    ///
    /// When `nil` (the default) the page is derived from ``baseURL``: a
    /// leading `api.` host label becomes `app.` and `/turnstile/verify` is
    /// appended, so the default `https://api.cupthread.com` resolves to
    /// `https://app.cupthread.com/turnstile/verify`. Set this explicitly for
    /// self-hosted deployments whose portal (or challenge page) lives on
    /// another origin. The page only needs to accept the widget parameters
    /// ``FeedbackClientConfiguration/makeTurnstileChallengeURL(for:siteKey:theme:locale:)``
    /// appends and bridge its result to the `turnstileBridge` message handler.
    public let turnstileChallengeURL: URL?

    /// Creates a configuration for a CupThread app.
    /// - Parameters:
    ///   - baseURL: The API root, normally `https://api.cupthread.com`.
    ///   - appKey: Your app's key from the CupThread developer console.
    ///     Surrounding whitespace is trimmed (SEC-22); keys that remain
    ///     blank, or contain characters outside `[A-Za-z0-9_.-]`, are
    ///     rejected with ``FeedbackClientError/invalidConfiguration(message:)``
    ///     when a request is dispatched.
    ///   - defaultPlatform: The platform reported with feedback submissions.
    ///     Defaults to `macos` on macOS and `ios` everywhere else (visionOS
    ///     and tvOS are iOS-family builds and report `ios`).
    ///   - requestID: Optional stable `X-Request-Id` sent with every request;
    ///     defaults to a per-request UUID.
    ///   - signingSecret: Optional SDK signing secret for HMAC-SHA256 request
    ///     signing when reporting paying-user attributes (`isPaying`, `plan`, `mrr`, `currency`).
    ///     > Warning: An embedded signing secret lets anyone who extracts it
    ///     > from the app binary forge verified payment attributes. Prefer the
    ///     > backend-delegated `userAttributesSigner` provider on
    ///     > ``FeedbackClient/init(configuration:session:turnstileTokenProvider:authenticationProvider:userAttributesSigner:)``.
    ///   - turnstileChallengeURL: Optional hosted challenge page for the
    ///     in-SDK human-verification sheet; defaults to `…/turnstile/verify`
    ///     on the portal origin derived from `baseURL`.
    public init(
        baseURL: URL,
        appKey: String,
        defaultPlatform: FeedbackPlatform = FeedbackPlatform.current,
        requestID: String? = nil,
        signingSecret: String? = nil,
        turnstileChallengeURL: URL? = nil
    ) {
        self.baseURL = baseURL
        self.appKey = AppKeyGrammar.normalized(appKey)
        self.defaultPlatform = defaultPlatform
        self.requestID = requestID
        self.signingSecret = signingSecret
        self.turnstileChallengeURL = turnstileChallengeURL
    }
}

/// The HTTP client for the CupThread feedback API.
///
/// One client serves every SDK surface — feedback, feature requests, roadmap,
/// and changelog. Create it once with a ``FeedbackClientConfiguration`` and
/// share it freely; the client is `Sendable` and stateless apart from three
/// shared helpers: the search throttle (``SearchRequestThrottle``), which the
/// search surfaces share so sustained typing stays below the API's per-IP
/// search rate limit, the short-TTL app-config cache
/// (``FeedbackClient/cachedAppConfig()``), which all surfaces share so
/// presenting any number of them costs at most one configuration GET per
/// TTL window, and the server-clock offset (``ServerClock``), which learns
/// the API's clock from response `Date` headers so signed payment-attribute
/// reports stay inside the server's signature freshness window on devices
/// with a skewed clock.
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
///
/// ## Redirect policy
///
/// Requests never follow redirects off the API origin. The default session
/// (used whenever no `session:` is injected) carries a redirect delegate that
/// refuses any redirect whose origin — scheme, host, and effective port —
/// differs from the original request's origin, so `Authorization: Bearer …`,
/// `X-User-Token`, and request bodies (which 307/308 redirects replay) are
/// never delivered to a third-party host, even by a compromised or misconfigured
/// API origin. A refused redirect surfaces the 3xx response itself, which
/// response validation reports as
/// ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``.
/// Same-origin redirects (e.g. relative `Location` paths on the API host) are
/// followed normally.
///
/// Every request the SDK dispatches — the attachment uploads and all JSON
/// endpoints alike — additionally installs that limiter as a *per-task
/// delegate*, so every SDK call refuses cross-origin redirects no matter
/// which session the client runs in — including a session injected here that
/// carries no redirect policy of its own (#561, #571).
///
/// ## Cookie isolation
///
/// The default session is also cookie-isolated (#585): it neither sends nor
/// stores cookies. Its configuration disables automatic `Cookie` headers and
/// carries a private, empty `HTTPCookieStorage`, so cookies the host app
/// holds for the API origin never attach to SDK requests, and API
/// `Set-Cookie` responses never reach the host app's shared cookie jar —
/// the SDK reads no cookies, so nothing is lost. The same isolation applies
/// to the image loader session on SDK surfaces. Requests additionally set
/// `httpShouldHandleCookies == false` per request, so even a session injected
/// here with the host's shared jar stays cookie-free on SDK calls; note that
/// such an injected session still owns whatever cookie policy its
/// configuration carries for requests the host dispatches through it itself.
public struct FeedbackClient: Sendable {
    /// The default maximum number of cursor pages to fetch during complete-data
    /// walks before gracefully stopping (100).
    ///
    /// With standard page sizes (100–200 items per page), 100 pages covers
    /// 10 000–20 000 items — comfortably above realistic public boards,
    /// comments threads, and changelogs while defending against runaway
    /// backends, shifting keyset cursors, or infinite pagination loops.
    public static let defaultMaxPages = 100

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
    /// Learned offset between the API's clock and this device's clock
    /// (``ServerClock``); feeds the signature timestamps of payment-attribute
    /// reports so a skewed device clock never produces a stale signature.
    let serverClock: ServerClock
    /// Optional provider the SDK consults for a Cloudflare Turnstile token on
    /// the human-verification-gated intake calls (feedback and feature-request
    /// submission, upload-session creation). Production intake is gated, so
    /// submissions cannot succeed without a token: hosts with their own
    /// verification flow — or a server-side exemption arrangement — supply it
    /// here. Called once per attempt (including the automatic single retry
    /// after a turnstile rejection) with the ``TurnstileChallenge`` naming the
    /// exact `(action, cdata)` binding the endpoint validates — render the
    /// widget (``TurnstileAction`` plus the app key as `cdata`) under that
    /// binding so the minted token verifies; unbound or cross-action tokens
    /// are rejected by the server. When `nil` (the default), gated submissions
    /// throw ``FeedbackClientError/turnstileRequired(message:requestId:)``
    /// after a single attempt.
    let turnstileTokenProvider: (@Sendable (TurnstileChallenge) async -> String?)?
    /// Resolves the signed-in end user's bearer token on demand.
    let authenticationProvider: (@Sendable () async -> String?)?
    /// Signs payment-attribute reports wherever the SDK signing secret
    /// actually lives (SEC-19) — normally the host's backend, which holds the
    /// entitlement truth and the secret, so neither ships inside the app
    /// binary. Called once per signed attempt (including the automatic single
    /// retry after `401 stale_signature`) with the ``UserAttributesSigningRequest``
    /// naming the exact canonical string to HMAC; the returned
    /// ``UserAttributesSignature`` is validated locally (signature grammar
    /// and timestamp equality, issue #579) and then sent verbatim. Return
    /// `nil` to fall back to the configured `signingSecret` (and then an
    /// unsigned report); thrown errors propagate to the caller. When `nil`
    /// (the default), signing falls back to the embedded `signingSecret`
    /// configuration.
    let userAttributesSigner: (@Sendable (UserAttributesSigningRequest) async throws -> UserAttributesSignature?)?

    /// The process-wide session used by clients that do not inject one: built
    /// from the default configuration with `SameOriginRedirectLimiter`
    /// installed, so every request refuses redirects that leave the original
    /// request's origin (see the redirect policy on ``FeedbackClient``).
    /// Cached in a static so all default clients share one session — and one
    /// delegate — for the process lifetime. Hosts that issue their own
    /// requests against the same API origin can reuse this session to opt
    /// into the same policy.
    ///
    /// The session is cookie-isolated (issue #585): its configuration carries
    /// `httpShouldSetCookies == false` and a private, empty
    /// `HTTPCookieStorage`, so ambient cookies the host app holds for the API
    /// origin are never attached to SDK requests and API `Set-Cookie`
    /// responses never reach the host app's shared cookie jar. The SDK reads
    /// no cookies, so nothing is lost.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = HTTPCookieStorage()
        return URLSession(
            configuration: configuration,
            delegate: SameOriginRedirectLimiter(),
            delegateQueue: nil
        )
    }()

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
    ///     custom `URLProtocol` (tests) or custom timeouts; when omitted,
    ///     requests run in a process-wide shared session that refuses
    ///     cross-origin redirects (see “Redirect policy” on ``FeedbackClient``).
    ///     Injected sessions are not modified — every SDK request enforces the
    ///     same redirect policy per-task regardless (#561, #571), so no
    ///     session-level redirect configuration is required.
    ///   - turnstileTokenProvider: Async closure resolving a Cloudflare
    ///     Turnstile token for gated intake calls, `nil` when none is
    ///     available. Called with the ``TurnstileChallenge`` naming the
    ///     `(action, cdata)` binding the endpoint validates — `feedback` for
    ///     `POST /api/v1/feedback` and upload-session creation,
    ///     `feature-request` for `POST /api/v1/feature-requests`, always with
    ///     the app key as `cdata` — once per attempt, so it can mint a fresh
    ///     token each time. Render the widget under that exact binding;
    ///     unbound or cross-action tokens are rejected by the server.
    ///   - authenticationProvider: Async closure resolving the signed-in
    ///     user's bearer token, `nil` when signed out. Called once per
    ///     authenticated request, so it can refresh an expiring token.
    ///   - userAttributesSigner: Async closure signing payment-attribute
    ///     reports wherever the SDK signing secret lives — normally your
    ///     backend (SEC-19). Called with the ``UserAttributesSigningRequest``
    ///     carrying the exact canonical string to HMAC-SHA256 with the secret;
    ///     return the ``UserAttributesSignature`` to send, or `nil` to fall
    ///     back to the configured `signingSecret` (and then an unsigned
    ///     report). Called once per signed attempt, including the automatic
    ///     single retry after a `stale_signature` rejection, so it can mint a
    ///     fresh signature each time. When `nil` (the default), signing uses
    ///     the embedded `signingSecret` configuration only.
    public init(
        configuration: FeedbackClientConfiguration,
        session: URLSession = FeedbackClient.defaultSession,
        turnstileTokenProvider: (@Sendable (TurnstileChallenge) async -> String?)? = nil,
        authenticationProvider: (@Sendable () async -> String?)? = nil,
        userAttributesSigner: (@Sendable (UserAttributesSigningRequest) async throws -> UserAttributesSignature?)? = nil
    ) {
        self.init(
            configuration: configuration,
            session: session,
            overlayPresenter: nil,
            turnstileTokenProvider: turnstileTokenProvider,
            authenticationProvider: authenticationProvider,
            userAttributesSigner: userAttributesSigner
        )
    }

    init(
        configuration: FeedbackClientConfiguration,
        session: URLSession = FeedbackClient.defaultSession,
        overlayPresenter: (any ChangelogOverlayPresenter)? = nil,
        searchThrottle: SearchRequestThrottle? = nil,
        tokenStore: UserTokenStore? = nil,
        configStore: AppConfigStore? = nil,
        serverClock: ServerClock? = nil,
        turnstileTokenProvider: (@Sendable (TurnstileChallenge) async -> String?)? = nil,
        authenticationProvider: (@Sendable () async -> String?)? = nil,
        userAttributesSigner: (@Sendable (UserAttributesSigningRequest) async throws -> UserAttributesSignature?)? = nil
    ) {
        self.configuration = configuration
        self.session = session
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.overlayPresenter = overlayPresenter
        self.authenticationProvider = authenticationProvider
        self.searchThrottle = searchThrottle ?? SearchRequestThrottle()
        self.tokenStore = tokenStore ?? UserTokenStore(appKey: configuration.appKey)
        self.configStore = configStore ?? AppConfigStore(
            lastGood: SdkConfigCache(appKey: configuration.appKey)
        )
        self.serverClock = serverClock ?? ServerClock()
        self.turnstileTokenProvider = turnstileTokenProvider
        self.userAttributesSigner = userAttributesSigner
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
    /// is sent as `turnstileToken`; the provider is consulted with the
    /// ``TurnstileAction/feedback`` binding (the app key as `cdata`), so
    /// render the widget under that exact action. Production intake is gated
    /// behind Cloudflare Turnstile: if the server rejects the submission with
    /// the human-verification gate (HTTP 403), the SDK asks the provider for
    /// a fresh token under the same binding and retries exactly once before
    /// throwing.
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
    ///     identity across session creation and feedback submission. Authenticated callers attach
    ///     the client's bearer token via the configured `authenticationProvider`.
    ///   - turnstileToken: Optional Turnstile token minted outside this client —
    ///     e.g. by ``TurnstileChallengeSheet`` after the gate rejected an earlier
    ///     attempt. Used for the first attempt verbatim; the configured
    ///     `turnstileTokenProvider` (when any) still backs the single automatic
    ///     retry. Mint it under the ``TurnstileAction/feedback`` binding.
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
    ///   ``FeedbackClientError/alreadyFinalized(message:requestId:)`` when an attachment
    ///   referenced in the submission was already finalized into another submission
    ///   (HTTP 409 `already_finalized`); the losing request creates no duplicate submission
    ///   and consumes no quota — callers must not retry with the same upload IDs (#256, #257, CupThread/SaaS#579),
    ///   ``FeedbackClientError/authenticationRequired`` or
    ///   ``FeedbackClientError/forbidden(message:requestId:)`` when anonymous
    ///   feedback is disabled or the platform is outside the console's
    ///   allow-list (HTTP 401/403),
    ///   ``FeedbackClientError/unexpectedStatus(code:message:requestId:)`` for other
    ///   server rejections (successful submissions accept HTTP 200, 201, and 202),
    ///   ``FeedbackClientError/invalidResponse`` when the response cannot be interpreted, or
    ///   ``FeedbackClientError/textTooLong`` when the encoded payload exceeds the
    ///   client-side intake byte budget (BUG-18) — rejected locally with no network
    ///   round trip; shorten the free-text fields and submit again. A draft whose
    ///   fields exceed the server's per-field intake caps (#578) also throws
    ///   ``FeedbackClientError/textTooLong`` locally, before the Turnstile token
    ///   provider is consulted or any request is sent.
    ///   A draft whose trimmed `title` is shorter than
    ///   ``IntakeTextLimits/minTitleLength`` or whose trimmed `description` is
    ///   shorter than ``IntakeTextLimits/minDescriptionLength`` also throws
    ///   ``FeedbackClientError/invalidResponse`` locally (BUG-32), before the
    ///   Turnstile token provider is consulted or any request is sent.
    ///   A draft whose `reporterEmail` is present but implausibly shaped or
    ///   over ``IntakeTextLimits/maxEmailLength`` code points also throws
    ///   ``FeedbackClientError/invalidEmailAddress(field:requestId:)`` locally
    ///   (#606), before the Turnstile token provider is consulted or any
    ///   request is sent — the same plausibility gate the changelog subscribe
    ///   path applies (#419); the server can only answer such an address with
    ///   `400 Validation failed`.
    public func submit(
        _ draft: FeedbackDraft,
        userToken: String? = nil,
        turnstileToken: String? = nil
    ) async throws -> FeedbackSubmissionResult {
        // Reject a non-nil blank or newline-bearing caller token before the
        // Turnstile provider is consulted or any fallback runs (#497); `nil`
        // preserves anonymous submission and attachment-store fallback.
        let validatedToken = try validatedUserToken(userToken)
        try validateIntakeMinimums(in: draft)
        try validateIntakeCaps(in: draft)
        // An implausible contact address can only earn `400 Validation failed`
        // — reject it locally before the Turnstile provider is consulted (#606).
        try validateIntakeEmail(draft.reporterEmail.nilIfEmpty, field: "reporterEmail")
        let uploadIds = draft.attachments.compactMap(\.uploadId).nilIfEmpty
        let effectiveUserToken = resolvedSubmitUserToken(validatedToken, hasAttachments: uploadIds != nil)
        let data = try await sendWithTurnstileRetry(
            accepted: Self.acceptedSubmitStatuses,
            challenge: .feedback(appKey: configuration.appKey),
            initialToken: turnstileToken
        ) { token, requestID in
            var request = URLRequest(url: self.configuration.baseURL.appending(path: "/api/v1/feedback"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            try self.applyCorrelationHeaders(userToken: effectiveUserToken, requestID: requestID, to: &request)
            await self.applyBearerToken(to: &request)
            request.httpBody = try self.encodedIntakeBody(self.submissionPayload(
                for: draft,
                uploadIds: uploadIds,
                turnstileToken: token
            ))
            return request
        }
        return try decodeSuccess(FeedbackSubmissionResult.self, from: data)
    }

    private static let acceptedSubmitStatuses: Set<Int> = [200, 201, 202]

    /// Whether this client was created with an `authenticationProvider`.
    ///
    /// This reports **provider presence only** — not whether an end user is
    /// signed in right now. The provider's contract is to return `nil` while
    /// signed out, and hosts normally install it unconditionally, so a `true`
    /// value says nothing about the current session. SDK permission preflights
    /// must therefore not gate on this property: they resolve
    /// ``resolveAuthenticatedAccess()`` instead, so a signed-out user of a
    /// host with an installed provider still sees the deliberate signed-out
    /// state instead of requests that cannot succeed (issue #297). The
    /// property is kept for source compatibility with hosts that only need to
    /// know whether the SDK could act for a signed-in user at all.
    public var supportsAuthentication: Bool {
        authenticationProvider != nil
    }

    /// Resolves whether a request sent **right now** can carry the signed-in
    /// identity's bearer token: an `authenticationProvider` must be installed
    /// *and* return a non-empty, single-line token without newlines. `false`
    /// covers every signed-out shape — no provider at all, or a provider
    /// answering `nil`/blank/newline-bearing string because the user is signed
    /// out, the token cannot be refreshed, or the value contains newlines.
    ///
    /// Permission preflights gate on this resolved value and re-evaluate it on
    /// every load, so a sign-in (or sign-out) between two loads is picked up
    /// without recreating the surface. The result is deliberately not cached:
    /// the same provider backs ``applyBearerToken(to:)``, so a resolved `true`
    /// is exactly the condition under which the follow-up request attaches
    /// `Authorization: Bearer …`.
    func resolveAuthenticatedAccess() async -> Bool {
        guard let authenticationProvider else { return false }
        guard let token = await authenticationProvider()?.nilIfEmpty else { return false }
        return !token.contains(where: \.isNewline)
    }

    /// Resolves the signed-in identity's bearer token through the
    /// authentication provider and presents it as `Authorization: Bearer …`.
    /// A `nil` or blank provider result, or a token containing newlines (or no provider at all)
    /// leaves the header unset, preventing HTTP header injection and letting the
    /// server's `401 authentication_required` response decide the outcome.
    func applyBearerToken(to request: inout URLRequest) async {
        guard let authenticationProvider else { return }
        if let bearer = await authenticationProvider()?.nilIfEmpty,
           !bearer.contains(where: \.isNewline) {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
    }
}
