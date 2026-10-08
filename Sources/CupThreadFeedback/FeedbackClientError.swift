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
    /// An upload was rejected by the media-type policy (HTTP 415 or HTTP 400
    /// `unsupported_mime_type` / `executable_extension_prohibited`) — e.g. SVG,
    /// executable extension, or bytes that do not match the declared MIME type.
    /// Only PNG, JPEG, WebP, and GIF are accepted.
    case unsupportedMediaType(message: String?, requestId: String?)
    /// An upload exceeded the server's size limit (HTTP 413).
    case payloadTooLarge(message: String?, requestId: String?)
    /// The submission's free-text content exceeded the client-side payload
    /// budget and was rejected locally, before any network round trip
    /// (BUG-18). Shorten the text — typically the description or comment
    /// body — and submit again. The per-field caps live in
    /// ``IntakeTextLimits``; the server's `413` for uploads keeps mapping to
    /// ``FeedbackClientError/payloadTooLarge(message:requestId:)``.
    case textTooLong
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
    /// The app's workspace reached its daily upload storage quota
    /// (HTTP 429 `daily_storage_quota_exceeded`) and the upload session was
    /// not created. Sessions succeed again once the quota resets or the
    /// workspace's storage limit is upgraded in the developer console.
    case dailyStorageQuotaExceeded(message: String?, requestId: String?)
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
    /// Comments are not available for the requested feature request (HTTP 404) —
    /// e.g. comments are disabled for this item or the thread has not been initialized.
    /// `message` carries the raw server text for diagnostics; it is never shown to end users.
    case commentsUnavailable(message: String?, requestId: String?)
    /// The reply target no longer qualifies as a parent (HTTP 400
    /// `invalid_parent`) — the comment being replied to was hidden,
    /// soft-deleted, or belongs to a different feature request by the time
    /// the reply was submitted. Clear the composer's reply target and
    /// submit again to post a top-level comment. `message` carries the raw
    /// server text for diagnostics; it is never shown to end users.
    case invalidParent(message: String?, requestId: String?)
    /// The changelog subscription was rejected because the email address has not
    /// been verified (HTTP 403 `email_not_verified`). Prompt the user to use their
    /// signed-in account email.
    case emailNotVerified(message: String?, requestId: String?)
    /// A payment-attribute report (`isPaying`, `plan`, `mrr`, `currency`) was
    /// sent without the required HMAC signature
    /// (HTTP 422 `payment_attributes_require_signature`). Configure
    /// ``FeedbackClientConfiguration/signingSecret`` — or pass the
    /// `signingSecret` parameter — so ``FeedbackClient/updateUserAttributes``
    /// signs the report.
    case paymentAttributesRequireSignature(message: String?, requestId: String?)
    /// The app has no SDK signing secret configured in the CupThread console
    /// (HTTP 422 `sdk_signing_secret_not_configured`), so signed payment
    /// attributes cannot be accepted. Add the SDK signing secret for the app
    /// in the developer console.
    case sdkSigningSecretNotConfigured(message: String?, requestId: String?)
    /// The HMAC signature on a payment-attribute report did not verify
    /// (HTTP 401 `invalid_signature`) — the signing secret the SDK signed with
    /// does not match the one configured for the app in the developer console.
    case invalidSignature(message: String?, requestId: String?)
    /// The signature timestamp on a payment-attribute report fell outside the
    /// server's freshness window (HTTP 401 `stale_signature`) — typically
    /// device clock skew. Ensure the device clock is set correctly and let the
    /// SDK retry with a fresh signature.
    case staleSignature(message: String?, requestId: String?)
    /// The upload session expired before the file could be uploaded
    /// (HTTP 401 `session_expired` / `session_invalid_or_expired`). Remove
    /// and re-attach the file to create a fresh upload session and try again.
    case uploadSessionExpired(message: String?, requestId: String?)
    /// The upload session was invalid, unknown, or no longer pending
    /// (HTTP 401 `session_invalid`, HTTP 409 `session_not_pending` /
    /// `already_uploaded`). Remove and re-attach the file to create a fresh
    /// upload session and try again.
    case uploadSessionInvalid(message: String?, requestId: String?)
    /// A feedback submission referenced an attachment upload ID that was already
    /// finalized into another submission (HTTP 409 `already_finalized`).
    /// The losing request creates no duplicate submission and consumes no monthly quota.
    /// Callers must not retry with the same upload IDs; remove consumed attachments
    /// or treat the submission as already completed. `message` carries the raw server
    /// text for diagnostics; it is never shown to end users.
    case alreadyFinalized(message: String?, requestId: String?)
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
             .subscriptionInactive, .dailyStorageQuotaExceeded, .turnstileRequired,
             .commentsUnavailable, .emailNotVerified, .invalidParent,
             .paymentAttributesRequireSignature, .sdkSigningSecretNotConfigured,
             .invalidSignature, .staleSignature, .uploadSessionExpired, .uploadSessionInvalid,
             .alreadyFinalized, .textTooLong:
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

    /// The ` (request id: …)` display suffix for typed error copy. Kept in
    /// its own helper so `errorDescription` bodies carry catalog keys only
    /// (issue #266).
    private static func requestIdSuffix(_ requestId: String?) -> String {
        guard let requestId else { return "" }
        return " (request id: \(requestId))"
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
        case .dailyStorageQuotaExceeded(_, let requestId):
            return requestId
        case .turnstileRequired(_, let requestId):
            return requestId
        case .forbidden(_, let requestId):
            return requestId
        case .commentsUnavailable(_, let requestId):
            return requestId
        case .invalidParent(_, let requestId):
            return requestId
        case .emailNotVerified(_, let requestId):
            return requestId
        case .paymentAttributesRequireSignature(_, let requestId):
            return requestId
        case .sdkSigningSecretNotConfigured(_, let requestId):
            return requestId
        case .invalidSignature(_, let requestId):
            return requestId
        case .staleSignature(_, let requestId):
            return requestId
        case .uploadSessionExpired(_, let requestId):
            return requestId
        case .uploadSessionInvalid(_, let requestId):
            return requestId
        case .alreadyFinalized(_, let requestId):
            return requestId
        case .unexpectedStatus(_, _, let requestId):
            return requestId
        case .invalidResponse, .unreadableUploadResponse, .authenticationRequired, .userProfileNotFound, .textTooLong:
            return nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return CupThreadStrings.tr("cupthread.error.invalid_response")
        case .unreadableUploadResponse:
            return CupThreadStrings.tr("cupthread.error.unreadable_upload_response")
        case .authenticationRequired:
            return CupThreadStrings.tr("cupthread.error.auth_required")
        case .forbidden(_, let requestId):
            // Raw server body stays off the user-facing copy (#30); callers
            // can read the associated `message` programmatically.
            return CupThreadStrings.tr("cupthread.error.forbidden") + Self.requestIdSuffix(requestId)
        case .turnstileRequired(_, let requestId):
            return CupThreadStrings.tr("cupthread.error.turnstile_required") + Self.requestIdSuffix(requestId)
        case .scanRejected(_, let requestId):
            // Raw server scan detail stays off user-facing copy (#30, #154); callers
            // can read the associated detail via `scanDetail` or pattern matching.
            return CupThreadStrings.tr("cupthread.error.scan_rejected") + Self.requestIdSuffix(requestId)
        case .rateLimited(_, let requestId):
            // Same copy as `.unexpectedStatus(code: 429)` so one rate-limit
            // condition reads identically on every surface (issue #266).
            return CupThreadStrings.tr("cupthread.error.http_rate_limited") + Self.requestIdSuffix(requestId)
        case .unsupportedMediaType(_, let requestId):
            return CupThreadStrings.tr("cupthread.error.unsupported_media") + Self.requestIdSuffix(requestId)
        case .payloadTooLarge(_, let requestId):
            return CupThreadStrings.tr("cupthread.error.payload_too_large") + Self.requestIdSuffix(requestId)
        case .textTooLong:
            // Rejected client-side, so there is no request id to quote.
            return CupThreadStrings.tr("cupthread.error.text_too_long")
        case .uploaderIdentityRequired(_, let requestId):
            return CupThreadStrings.tr("cupthread.error.uploader_identity_required") + Self.requestIdSuffix(requestId)
        case .uploaderMismatch(_, let requestId):
            return CupThreadStrings.tr("cupthread.error.uploader_mismatch") + Self.requestIdSuffix(requestId)
        case .submissionQuotaExceeded(_, let requestId):
            return CupThreadStrings.tr("cupthread.error.quota_exceeded") + Self.requestIdSuffix(requestId)
        case .subscriptionInactive(_, let requestId):
            return CupThreadStrings.tr("cupthread.error.subscription_inactive") + Self.requestIdSuffix(requestId)
        case .dailyStorageQuotaExceeded(_, let requestId):
            return CupThreadStrings.tr("cupthread.error.daily_storage_quota_exceeded") + Self.requestIdSuffix(requestId)
        case .userProfileNotFound:
            return CupThreadStrings.tr("cupthread.error.profile_not_found")
        case .commentsUnavailable(_, let requestId):
            return CupThreadStrings.tr("cupthread.error.comments_unavailable") + Self.requestIdSuffix(requestId)
        case .invalidParent(_, let requestId):
            // Raw server body stays off the user-facing copy (#30); callers
            // can read the associated `message` programmatically.
            return CupThreadStrings.tr("cupthread.comments.invalid_parent") + Self.requestIdSuffix(requestId)
        case .emailNotVerified(_, let requestId):
            return CupThreadStrings.tr("cupthread.error.email_not_verified") + Self.requestIdSuffix(requestId)
        case .paymentAttributesRequireSignature(_, let requestId):
            return CupThreadStrings.tr("cupthread.error.signature_required") + Self.requestIdSuffix(requestId)
        case .sdkSigningSecretNotConfigured(_, let requestId):
            return CupThreadStrings.tr("cupthread.error.signing_secret_not_configured") + Self.requestIdSuffix(requestId)
        case .invalidSignature(_, let requestId):
            return CupThreadStrings.tr("cupthread.error.invalid_signature") + Self.requestIdSuffix(requestId)
        case .staleSignature(_, let requestId):
            return CupThreadStrings.tr("cupthread.error.stale_signature") + Self.requestIdSuffix(requestId)
        case .uploadSessionExpired(_, let requestId):
            return CupThreadStrings.tr("cupthread.error.upload_session_expired") + Self.requestIdSuffix(requestId)
        case .uploadSessionInvalid(_, let requestId):
            return CupThreadStrings.tr("cupthread.error.upload_session_invalid") + Self.requestIdSuffix(requestId)
        case .alreadyFinalized(_, let requestId):
            // Raw server body stays off the user-facing copy (#257); callers
            // can read the associated `message` programmatically.
            return CupThreadStrings.tr("cupthread.error.already_finalized") + Self.requestIdSuffix(requestId)
        case .unexpectedStatus(let code, _, let requestId):
            // The raw body stays on the case for diagnostics (`responseBody`);
            // only localized status copy is shown to users (#30).
            return Self.friendlyStatusMessage(code: code) + Self.requestIdSuffix(requestId)
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

    /// Convenience constructor for ``dailyStorageQuotaExceeded(message:requestId:)`` with no request id.
    static func dailyStorageQuotaExceeded(message: String? = nil) -> FeedbackClientError {
        .dailyStorageQuotaExceeded(message: message, requestId: nil)
    }

    /// Convenience constructor for ``forbidden(message:requestId:)`` with no request id.
    static func forbidden(message: String? = nil) -> FeedbackClientError {
        .forbidden(message: message, requestId: nil)
    }

    /// Convenience constructor for ``turnstileRequired(message:requestId:)`` with no details.
    static func turnstileRequired() -> FeedbackClientError {
        .turnstileRequired(message: nil, requestId: nil)
    }

    /// Convenience constructor for ``commentsUnavailable(message:requestId:)`` with no request id.
    static func commentsUnavailable(message: String? = nil) -> FeedbackClientError {
        .commentsUnavailable(message: message, requestId: nil)
    }

    /// Convenience constructor for ``invalidParent(message:requestId:)`` with no request id.
    static func invalidParent(message: String? = nil) -> FeedbackClientError {
        .invalidParent(message: message, requestId: nil)
    }

    /// Convenience constructor for ``emailNotVerified(message:requestId:)`` with no request id.
    static func emailNotVerified(message: String? = nil) -> FeedbackClientError {
        .emailNotVerified(message: message, requestId: nil)
    }

    /// Convenience constructor for ``paymentAttributesRequireSignature(message:requestId:)`` with no request id.
    static func paymentAttributesRequireSignature(message: String? = nil) -> FeedbackClientError {
        .paymentAttributesRequireSignature(message: message, requestId: nil)
    }

    /// Convenience constructor for ``sdkSigningSecretNotConfigured(message:requestId:)`` with no request id.
    static func sdkSigningSecretNotConfigured(message: String? = nil) -> FeedbackClientError {
        .sdkSigningSecretNotConfigured(message: message, requestId: nil)
    }

    /// Convenience constructor for ``invalidSignature(message:requestId:)`` with no request id.
    static func invalidSignature(message: String? = nil) -> FeedbackClientError {
        .invalidSignature(message: message, requestId: nil)
    }

    /// Convenience constructor for ``staleSignature(message:requestId:)`` with no request id.
    static func staleSignature(message: String? = nil) -> FeedbackClientError {
        .staleSignature(message: message, requestId: nil)
    }

    /// Convenience constructor for ``uploadSessionExpired(message:requestId:)`` with no request id.
    static func uploadSessionExpired(message: String? = nil) -> FeedbackClientError {
        .uploadSessionExpired(message: message, requestId: nil)
    }

    /// Convenience constructor for ``uploadSessionInvalid(message:requestId:)`` with no request id.
    static func uploadSessionInvalid(message: String? = nil) -> FeedbackClientError {
        .uploadSessionInvalid(message: message, requestId: nil)
    }

    /// Convenience constructor for ``alreadyFinalized(message:requestId:)`` with no request id.
    static func alreadyFinalized(message: String? = nil) -> FeedbackClientError {
        .alreadyFinalized(message: message, requestId: nil)
    }
}
