import Foundation

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
    /// The server's permission policy rejected the action (HTTP 403) — e.g.
    /// anonymous feedback or voting is disabled for the app in the CupThread
    /// console, or the reporting platform is outside the console's platform
    /// allow-list. The console switch, not the network, is the cause; SDK
    /// surfaces preflight-gate so this mostly appears when UI races a
    /// console change. `message` is the raw server text for diagnostics and
    /// is never shown to end users.
    case forbidden(message: String?, requestId: String?)
    /// An attachment referenced in the feedback submission was rejected by server-side content inspection
    /// (e.g. prohibited file types or malware signatures, HTTP `422 scan_rejected`). `message` carries the
    /// raw server rejection detail for diagnostics — see ``scanDetail``; it is never shown to end users.
    case scanRejected(message: String, requestId: String?)
    /// A metered action hit the server's per-client-IP rate limit (HTTP 429) —
    /// e.g. voting too fast, or a burst of uploads. Recoverable: wait for the
    /// rate-limit window before retrying.
    case rateLimited(message: String?, requestId: String?)
    /// An upload was rejected by the media-type policy (HTTP 415) — e.g. SVG,
    /// or bytes that do not match the declared MIME type. Only PNG, JPEG,
    /// WebP, and GIF are accepted.
    case unsupportedMediaType(message: String?, requestId: String?)
    /// An upload exceeded the server's size limit (HTTP 413).
    case payloadTooLarge(message: String?, requestId: String?)
    /// No end-user identity could be presented where one is required
    /// (HTTP 400 `uploader_identity_required`) — upload sessions are always
    /// bound to an uploader identity.
    case uploaderIdentityRequired(message: String?, requestId: String?)
    /// The request presented a different identity than the one that created
    /// the referenced upload session (HTTP 400 `uploader_mismatch`).
    /// Re-attach the file with the same `userToken` and try again.
    case uploaderMismatch(message: String?, requestId: String?)
    /// The app's workspace reached its monthly submission quota
    /// (HTTP 402 `tier_limit_submissions`) and the submission was not
    /// accepted. Submissions succeed again once the quota resets or the
    /// workspace's plan is upgraded in the developer console.
    case submissionQuotaExceeded(message: String?, requestId: String?)
    /// The app's workspace subscription is inactive or canceled
    /// (HTTP 402 `subscription_inactive`) and the submission was not
    /// accepted. Submissions succeed again once the workspace's subscription
    /// is reactivated.
    case subscriptionInactive(message: String?, requestId: String?)
    /// The server's Cloudflare Turnstile human-verification gate rejected the
    /// submission (HTTP 403) and no fresh token could be presented. Create
    /// the client with a `turnstileTokenProvider` — or arrange a server-side
    /// exemption with the app's operator — so intake can succeed; retrying
    /// the submission unchanged will not.
    case turnstileRequired(message: String?, requestId: String?)
    /// The requested user profile could not be found (HTTP 404). `message`
    /// carries the raw response body for diagnostics — see ``responseBody``;
    /// it is never shown to end users.
    case userProfileNotFound(message: String?)
    /// The server answered with a status the SDK does not handle. `message`
    /// carries the **unsanitized raw response body** for diagnostics (an
    /// HTML/XML gateway error page, a stack trace, …) — read it through
    /// ``responseBody`` for logs and support tickets. It is never shown to
    /// end users: ``LocalizedError/errorDescription`` renders localized,
    /// status-based copy instead. `requestId` is the response's
    /// `X-Request-Id` correlation id for support requests.
    case unexpectedStatus(code: Int, message: String, requestId: String?)

    /// The unsanitized server response body this error carries, when one was
    /// captured — an HTML/XML gateway error page, a stack trace, or a plain
    /// text error. Intended for logging and support tickets, never for
    /// display: every user-facing SDK surface renders
    /// ``LocalizedError/errorDescription`` copy, which never embeds this text.
    public var responseBody: String? {
        switch self {
        case .unexpectedStatus(_, let message, _):
            return message
        case .userProfileNotFound(let message):
            return message
        case .invalidResponse, .unreadableUploadResponse, .authenticationRequired,
             .forbidden, .scanRejected, .rateLimited, .unsupportedMediaType, .payloadTooLarge,
             .uploaderIdentityRequired, .uploaderMismatch, .submissionQuotaExceeded,
             .subscriptionInactive, .turnstileRequired:
            return nil
        }
    }

    /// Raw diagnostic detail returned by server-side content inspection for
    /// ``scanRejected(message:requestId:)`` (HTTP 422 `scan_rejected`),
    /// describing why the attachment was refused (e.g. malware signature or
    /// prohibited file type). Kept for logging and support; never shown in
    /// user-facing UI copy.
    public var scanDetail: String? {
        switch self {
        case .scanRejected(let message, _):
            return message
        default:
            return nil
        }
    }

    /// End-user copy for a status the SDK does not map to a typed case —
    /// localized, and free of any server-controlled text.
    private static func friendlyStatusMessage(code: Int) -> String {
        switch code {
        case 401:
            return CupThreadStrings.tr("cupthread.error.http_unauthorized")
        case 404:
            return CupThreadStrings.tr("cupthread.error.http_not_found")
        case 429:
            return CupThreadStrings.tr("cupthread.error.http_rate_limited")
        case 500...599:
            return CupThreadStrings.tr("cupthread.error.http_server_busy")
        default:
            return CupThreadStrings.tr("cupthread.error.request_failed")
        }
    }

    /// The `X-Request-Id` correlation identifier associated with this error, if available.
    public var requestId: String? {
        switch self {
        case .scanRejected(_, let requestId):
            return requestId
        case .rateLimited(_, let requestId):
            return requestId
        case .unsupportedMediaType(_, let requestId):
            return requestId
        case .payloadTooLarge(_, let requestId):
            return requestId
        case .uploaderIdentityRequired(_, let requestId):
            return requestId
        case .uploaderMismatch(_, let requestId):
            return requestId
        case .submissionQuotaExceeded(_, let requestId):
            return requestId
        case .subscriptionInactive(_, let requestId):
            return requestId
        case .turnstileRequired(_, let requestId):
            return requestId
        case .forbidden(_, let requestId):
            return requestId
        case .unexpectedStatus(_, _, let requestId):
            return requestId
        case .invalidResponse, .unreadableUploadResponse, .authenticationRequired, .userProfileNotFound:
            return nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The feedback server returned an invalid response."
        case .unreadableUploadResponse:
            return "The feedback server returned an unreadable upload response."
        case .authenticationRequired:
            return "This action is only available to signed-in users."
        case .forbidden(_, let requestId):
            // Raw server body stays off the user-facing copy (#30); callers
            // can read the associated `message` programmatically.
            let suffix = requestId.map { " (request id: \($0))" } ?? ""
            return CupThreadStrings.tr("cupthread.error.forbidden") + suffix
        case .turnstileRequired(_, let requestId):
            let suffix = requestId.map { " (request id: \($0))" } ?? ""
            return CupThreadStrings.tr("cupthread.error.turnstile_required") + suffix
        case .scanRejected(_, let requestId):
            // Raw server scan detail stays off user-facing copy (#30, #154); callers
            // can read the associated detail via `scanDetail` or pattern matching.
            let suffix = requestId.map { " (request id: \($0))" } ?? ""
            return "The referenced attachment could not be uploaded due to content inspection rejection.\(suffix)"
        case .rateLimited(_, let requestId):
            let suffix = requestId.map { " (request id: \($0))" } ?? ""
            return "You're doing that too often. Please try again in a minute.\(suffix)"
        case .unsupportedMediaType(_, let requestId):
            let suffix = requestId.map { " (request id: \($0))" } ?? ""
            return "That image type isn't supported. Please attach a PNG, JPEG, WebP, or GIF.\(suffix)"
        case .payloadTooLarge(_, let requestId):
            let suffix = requestId.map { " (request id: \($0))" } ?? ""
            return "That file is too large to upload.\(suffix)"
        case .uploaderIdentityRequired(_, let requestId):
            let suffix = requestId.map { " (request id: \($0))" } ?? ""
            return "Uploads require an end-user identity. Pass a userToken (see UserTokenStore) when uploading attachments.\(suffix)"
        case .uploaderMismatch(_, let requestId):
            let suffix = requestId.map { " (request id: \($0))" } ?? ""
            return "This attachment was uploaded with a different identity. Please remove and re-attach it, then try again.\(suffix)"
        case .submissionQuotaExceeded(_, let requestId):
            let suffix = requestId.map { " (request id: \($0))" } ?? ""
            return "This app has reached its submission limit for this month. Please try again later.\(suffix)"
        case .subscriptionInactive(_, let requestId):
            let suffix = requestId.map { " (request id: \($0))" } ?? ""
            return "Submissions are unavailable for this app right now. Please try again later.\(suffix)"
        case .userProfileNotFound:
            return "This user profile is no longer available."
        case .unexpectedStatus(let code, _, let requestId):
            // The raw body stays on the case for diagnostics (`responseBody`);
            // only localized status copy is shown to users (#30).
            let suffix = requestId.map { " (request id: \($0))" } ?? ""
            return Self.friendlyStatusMessage(code: code) + suffix
        }
    }
}

public extension FeedbackClientError {
    /// Convenience constructor for ``scanRejected(message:requestId:)`` with no request id.
    static func scanRejected(message: String) -> FeedbackClientError {
        .scanRejected(message: message, requestId: nil)
    }

    /// Convenience constructor for ``rateLimited(message:requestId:)`` with no request id.
    static func rateLimited(message: String? = nil) -> FeedbackClientError {
        .rateLimited(message: message, requestId: nil)
    }

    /// Convenience constructor for ``unsupportedMediaType(message:requestId:)`` with no request id.
    static func unsupportedMediaType(message: String? = nil) -> FeedbackClientError {
        .unsupportedMediaType(message: message, requestId: nil)
    }

    /// Convenience constructor for ``payloadTooLarge(message:requestId:)`` with no request id.
    static func payloadTooLarge(message: String? = nil) -> FeedbackClientError {
        .payloadTooLarge(message: message, requestId: nil)
    }

    /// Convenience constructor for ``uploaderIdentityRequired(message:requestId:)`` with no request id.
    static func uploaderIdentityRequired(message: String? = nil) -> FeedbackClientError {
        .uploaderIdentityRequired(message: message, requestId: nil)
    }

    /// Convenience constructor for ``uploaderMismatch(message:requestId:)`` with no request id.
    static func uploaderMismatch(message: String? = nil) -> FeedbackClientError {
        .uploaderMismatch(message: message, requestId: nil)
    }

    /// Convenience constructor for ``submissionQuotaExceeded(message:requestId:)`` with no request id.
    static func submissionQuotaExceeded(message: String? = nil) -> FeedbackClientError {
        .submissionQuotaExceeded(message: message, requestId: nil)
    }

    /// Convenience constructor for ``subscriptionInactive(message:requestId:)`` with no request id.
    static func subscriptionInactive(message: String? = nil) -> FeedbackClientError {
        .subscriptionInactive(message: message, requestId: nil)
    }

    /// Convenience constructor for ``forbidden(message:requestId:)`` with no request id.
    static func forbidden(message: String? = nil) -> FeedbackClientError {
        .forbidden(message: message, requestId: nil)
    }

    /// Convenience constructor for ``turnstileRequired(message:requestId:)`` with no details.
    static func turnstileRequired() -> FeedbackClientError {
        .turnstileRequired(message: nil, requestId: nil)
    }
}
