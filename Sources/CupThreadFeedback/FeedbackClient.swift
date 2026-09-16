import Foundation

/// Connection settings for a ``FeedbackClient``.
///
/// Create one configuration per CupThread app and share it across clients:
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

/// Errors thrown by ``FeedbackClient`` network calls.
public enum FeedbackClientError: LocalizedError, Equatable, Sendable {
    /// The server response could not be interpreted as HTTP.
    case invalidResponse
    /// The upload endpoint returned a success response (200, 201, or 202)
    /// whose body could not be decoded.
    case unreadableUploadResponse
    /// The endpoint requires a signed-in user — e.g. the app's changelog
    /// is restricted and anonymous access is disabled (`401 authentication_required`).
    case authenticationRequired
    /// An attachment referenced in the feedback submission was rejected by server-side content inspection
    /// (e.g. prohibited file types or malware signatures, HTTP `422 scan_rejected`).
    case scanRejected(message: String)
    /// A metered action hit the server's per-client-IP rate limit (HTTP 429) —
    /// e.g. voting too fast, or a burst of uploads. Recoverable: wait for the
    /// rate-limit window before retrying.
    case rateLimited(message: String?)
    /// An upload was rejected by the media-type policy (HTTP 415) — e.g. SVG,
    /// or bytes that do not match the declared MIME type. Only PNG, JPEG,
    /// WebP, and GIF are accepted.
    case unsupportedMediaType(message: String?)
    /// An upload exceeded the server's size limit (HTTP 413).
    case payloadTooLarge(message: String?)
    /// No end-user identity could be presented where one is required
    /// (HTTP 400 `uploader_identity_required`) — upload sessions are always
    /// bound to an uploader identity.
    case uploaderIdentityRequired(message: String?)
    /// The request presented a different identity than the one that created
    /// the referenced upload session (HTTP 400 `uploader_mismatch`).
    /// Re-attach the file with the same `userToken` and try again.
    case uploaderMismatch(message: String?)
    /// The app's workspace reached its monthly submission quota
    /// (HTTP 402 `tier_limit_submissions`) and the submission was not
    /// accepted. Submissions succeed again once the quota resets or the
    /// workspace's plan is upgraded in the developer console.
    case submissionQuotaExceeded(message: String?)
    /// The app's workspace subscription is inactive or canceled
    /// (HTTP 402 `subscription_inactive`) and the submission was not
    /// accepted. Submissions succeed again once the workspace's subscription
    /// is reactivated.
    case subscriptionInactive(message: String?)
    /// The requested user profile could not be found (HTTP 404).
    case userProfileNotFound(message: String?)
    /// The server answered with a status the SDK does not handle. `message`
    /// carries the raw response body for debugging; `requestId` is the
    /// response's `X-Request-Id` correlation id for support requests.
    case unexpectedStatus(code: Int, message: String, requestId: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The feedback server returned an invalid response."
        case .unreadableUploadResponse:
            return "The feedback server returned an unreadable upload response."
        case .authenticationRequired:
            return "This action is only available to signed-in users."
        case .scanRejected(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "The referenced attachment could not be uploaded due to content inspection rejection."
            }
            return "The referenced attachment could not be uploaded due to content inspection rejection: \(trimmed)"
        case .rateLimited:
            return "You're doing that too often. Please try again in a minute."
        case .unsupportedMediaType:
            return "That image type isn't supported. Please attach a PNG, JPEG, WebP, or GIF."
        case .payloadTooLarge:
            return "That file is too large to upload."
        case .uploaderIdentityRequired:
            return "Uploads require an end-user identity. Pass a userToken (see UserTokenStore) when uploading attachments."
        case .uploaderMismatch:
            return "This attachment was uploaded with a different identity. Please remove and re-attach it, then try again."
        case .submissionQuotaExceeded:
            return "This app has reached its submission limit for this month. Please try again later."
        case .subscriptionInactive:
            return "Submissions are unavailable for this app right now. Please try again later."
        case .userProfileNotFound(let message):
            let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
            return "This user profile is no longer available."
        case .unexpectedStatus(let code, let message, let requestId):
            let suffix = requestId.map { " (request id: \($0))" } ?? ""
            return "The feedback request failed (\(code))\(suffix): \(message)"
        }
    }
}

private struct FeedbackSubmissionPayload: Codable, Sendable {
    let appKey: String
    let title: String
    let description: String
    let reporterName: String?
    let reporterEmail: String?
    let platform: FeedbackPlatform
    let appVersion: String?
    let buildNumber: String?
    let metadata: [String: String]
    let uploadIds: [String]?
}

/// The HTTP client for the CupThread feedback API.
///
/// One client serves every SDK surface — feedback, feature requests, roadmap,
/// and changelog. Create it once with a ``FeedbackClientConfiguration`` and
/// share it freely; the client is `Sendable` and stateless apart from the
/// built-in search throttle (``SearchRequestThrottle``), which the search
/// surfaces share so sustained typing stays below the API's per-IP
/// search rate limit.
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

    /// Creates a client for a CupThread app.
    /// - Parameters:
    ///   - configuration: API root, app key, and default reported platform.
    ///   - session: The URL session requests run in. Override to install a
    ///     custom `URLProtocol` (tests) or custom timeouts; defaults to `.shared`.
    public init(
        configuration: FeedbackClientConfiguration,
        session: URLSession = .shared
    ) {
        self.init(configuration: configuration, session: session, overlayPresenter: nil)
    }

    init(
        configuration: FeedbackClientConfiguration,
        session: URLSession = .shared,
        overlayPresenter: (any ChangelogOverlayPresenter)? = nil
    ) {
        self.configuration = configuration
        self.session = session
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.overlayPresenter = overlayPresenter
        self.searchThrottle = SearchRequestThrottle()
    }

    /// Submits a feedback draft.
    ///
    /// Titles and descriptions are trimmed; empty contact fields, version
    /// strings, and attachment lists are omitted from the payload. Attachments
    /// contributed by ``uploadAttachment(data:filename:mimeType:userToken:)``
    /// are sent as `uploadIds` referencing their upload session. The SDK adds
    /// `sdk`, `platform`, and `submittedAt` metadata automatically and applies
    /// the server's metadata redaction contract locally (credential-looking
    /// keys are redacted, values truncated, oversized payloads shrunk).
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
    ///     the SDK falls back to ``UserTokenStore/shared`` so anonymous flows keep a stable
    ///     identity across session creation and feedback submission.
    /// - Returns: The server's receipt, including the submission id and any warning.
    /// - Throws: ``FeedbackClientError/scanRejected(message:)`` when an attachment
    ///   referenced in the submission was rejected by server-side content scan (HTTP 422 `scan_rejected`);
    ///   ``FeedbackClientError/submissionQuotaExceeded(message:)`` when the app's
    ///   workspace has reached its monthly submission quota (HTTP 402 `tier_limit_submissions`),
    ///   ``FeedbackClientError/subscriptionInactive(message:)`` when the workspace
    ///   subscription is inactive or canceled (HTTP 402 `subscription_inactive`),
    ///   ``FeedbackClientError/rateLimited`` on HTTP 429,
    ///   ``FeedbackClientError/unexpectedStatus(code:message:requestId:)`` for other
    ///   server rejections (successful submissions accept HTTP 200, 201, and 202), or
    ///   ``FeedbackClientError/invalidResponse`` when the response cannot be interpreted.
    public func submit(
        _ draft: FeedbackDraft,
        userToken: String? = nil
    ) async throws -> FeedbackSubmissionResult {
        let uploadIds = draft.attachments.compactMap(\.uploadId).nilIfEmpty
        let payload = FeedbackSubmissionPayload(
            appKey: configuration.appKey,
            title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: draft.description.trimmingCharacters(in: .whitespacesAndNewlines),
            reporterName: draft.reporterName.nilIfEmpty,
            reporterEmail: draft.reporterEmail.nilIfEmpty,
            platform: draft.platform,
            appVersion: draft.appVersion.nilIfEmpty,
            buildNumber: draft.buildNumber.nilIfEmpty,
            metadata: sanitizedMetadata(from: draft),
            uploadIds: uploadIds
        )

        var request = URLRequest(url: configuration.baseURL.appending(path: "/api/v1/feedback"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let effectiveUserToken = resolvedSubmitUserToken(userToken, hasAttachments: uploadIds != nil)
        applyCorrelationHeaders(userToken: effectiveUserToken, requestID: nextRequestID(), to: &request)
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }

        try validateResponse(httpResponse, data: data, accepted: Self.acceptedSubmitStatuses)

        return try decoder.decode(FeedbackSubmissionResult.self, from: data)
    }

    private func sanitizedMetadata(from draft: FeedbackDraft) -> [String: String] {
        let reserved = [
            "sdk": "cupthread-apple",
            "platform": draft.platform.rawValue,
            "submittedAt": ISO8601DateFormatter().string(from: .now)
        ]
        return FeedbackMetadataSanitizer.sanitize(draft.metadata, reserved: reserved)
    }

    private static let acceptedSubmitStatuses: Set<Int> = [200, 201, 202]

    /// Resolves an anonymous identity for requests that require one.
    /// Falls back to the shared anonymous token store when the caller did not pass one.
    func resolvedIdentity(_ userToken: String?) -> String? {
        userToken?.nilIfEmpty ?? UserTokenStore.shared.token
    }

    /// Resolves the identity to send on feedback submissions.
    ///
    /// When `userToken` is `nil` and the submission contains attachments with upload IDs,
    /// falls back to ``UserTokenStore/shared`` so the submitter matches the uploader identity.
    /// When there are no attachments and `userToken` is `nil`, the header is omitted.
    func resolvedSubmitUserToken(_ userToken: String?, hasAttachments: Bool) -> String? {
        if let token = userToken?.nilIfEmpty {
            return token
        }
        return hasAttachments ? resolvedIdentity(userToken) : nil
    }

    /// Sets the `X-User-Token` header when a token is present.
    func applyUserToken(_ userToken: String?, to request: inout URLRequest) {
        if let userToken = userToken?.nilIfEmpty {
            request.setValue(userToken, forHTTPHeaderField: "X-User-Token")
        }
    }
}

extension String {
    /// The string trimmed of surrounding whitespace, or `nil` when empty.
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Array where Element == String {
    var nilIfEmpty: [String]? {
        isEmpty ? nil : self
    }
}
