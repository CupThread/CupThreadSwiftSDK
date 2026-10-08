import Foundation

// Extracted from ClientSupport.swift so the response plumbing and the
// envelope→typed-error mapping each stay under the file-size budget.

extension FeedbackClient {
    /// Maps the API's code-qualified failure envelopes to typed errors
    /// (each pair of status and machine-readable `code` maps to exactly one
    /// case). Returns `nil` for envelopes without a known pairing, leaving
    /// the mapping to the caller.
    static func typedError(
        statusCode: Int,
        code: String?,
        envelopeMessage: String?,
        requestId: String?
    ) -> FeedbackClientError? {
        switch (statusCode, code) {
        case (401, "authentication_required"):
            // Signed-in-only action (restricted changelog, comment creation):
            // every endpoint maps this envelope to the same typed error.
            return .authenticationRequired
        case (422, "scan_rejected"):
            // An uploadId referenced by the submission failed the
            // server-side content inspection (PRIV-02 media policy).
            return .scanRejected(message: envelopeMessage ?? "", requestId: requestId)
        case (403, let turnstileCode) where isTurnstileRejection(code: turnstileCode, message: envelopeMessage):
            // The Turnstile human-verification gate (#53): the uploads
            // sessions route rejects with a machine-readable code; the intake
            // endpoints return only the human message until their Phase 0
            // code ships, so the message matches as a fallback.
            return .turnstileRequired(message: envelopeMessage, requestId: requestId)
        case (400, _):
            return badRequestTypedError(code: code, envelopeMessage: envelopeMessage, requestId: requestId)
        case (403, "email_not_verified"):
            return .emailNotVerified(message: envelopeMessage, requestId: requestId)
        case (409, "already_finalized"):
            // A concurrent or retried submission already finalized the referenced
            // uploadId (#257, SaaS #579). No duplicate submission was created.
            return .alreadyFinalized(message: envelopeMessage, requestId: requestId)
        default:
            return uploadSessionLifecycleTypedError(
                statusCode: statusCode,
                code: code,
                envelopeMessage: envelopeMessage,
                requestId: requestId
            ) ?? quotaTypedError(
                statusCode: statusCode,
                code: code,
                envelopeMessage: envelopeMessage,
                requestId: requestId
            ) ?? signatureTypedError(
                statusCode: statusCode,
                code: code,
                envelopeMessage: envelopeMessage,
                requestId: requestId
            ) ?? signatureTypedError(
                statusCode: statusCode,
                code: code,
                envelopeMessage: envelopeMessage,
                requestId: requestId
            )
        }
    }

    /// Maps status 400 failure envelopes to typed errors (uploader identity/mismatch,
    /// invalid parent comment, disallowed MIME / executable extension).
    private static func badRequestTypedError(
        code: String?,
        envelopeMessage: String?,
        requestId: String?
    ) -> FeedbackClientError? {
        switch code {
        case "uploader_identity_required":
            return .uploaderIdentityRequired(message: envelopeMessage, requestId: requestId)
        case "uploader_mismatch":
            return .uploaderMismatch(message: envelopeMessage, requestId: requestId)
        case "invalid_parent":
            return .invalidParent(message: envelopeMessage, requestId: requestId)
        case "unsupported_mime_type", "executable_extension_prohibited":
            return .unsupportedMediaType(message: envelopeMessage, requestId: requestId)
        default:
            return nil
        }
    }

    /// Maps workspace quota and subscription metering envelopes (API-12, #112).
    private static func quotaTypedError(
        statusCode: Int,
        code: String?,
        envelopeMessage: String?,
        requestId: String?
    ) -> FeedbackClientError? {
        switch (statusCode, code) {
        case (402, "tier_limit_submissions"):
            return .submissionQuotaExceeded(message: envelopeMessage, requestId: requestId)
        case (402, "subscription_inactive"):
            return .subscriptionInactive(message: envelopeMessage, requestId: requestId)
        case (429, "daily_storage_quota_exceeded"):
            return .dailyStorageQuotaExceeded(message: envelopeMessage, requestId: requestId)
        default:
            return nil
        }
    }

    /// Maps the payment-attribute signature failure envelopes on
    /// `PUT /api/v1/public/apps/{appKey}/user` (issue #238): each pairing
    /// gets a typed case so hosts can switch on the machine code and never
    /// see the signed-in `401` copy for a signing problem. Returns `nil`
    /// for anything else, leaving the mapping to the caller.
    private static func signatureTypedError(
        statusCode: Int,
        code: String?,
        envelopeMessage: String?,
        requestId: String?
    ) -> FeedbackClientError? {
        switch (statusCode, code) {
        case (422, "payment_attributes_require_signature"):
            return .paymentAttributesRequireSignature(message: envelopeMessage, requestId: requestId)
        case (422, "sdk_signing_secret_not_configured"):
            return .sdkSigningSecretNotConfigured(message: envelopeMessage, requestId: requestId)
        case (401, "invalid_signature"):
            return .invalidSignature(message: envelopeMessage, requestId: requestId)
        case (401, "stale_signature"):
            return .staleSignature(message: envelopeMessage, requestId: requestId)
        default:
            return nil
        }
    }

    /// Resolves an anonymous identity for requests that require one.
    /// Falls back to this client's app-key-scoped token store when the caller
    /// did not pass one, so identities never bleed across app keys.
    func resolvedIdentity(_ userToken: String?) -> String? {
        userToken?.nilIfEmpty ?? tokenStore.token
    }

    /// Resolves the identity to send on feedback submissions.
    ///
    /// When `userToken` is `nil` and the submission contains attachments with upload IDs,
    /// falls back to this client's app-key-scoped store so the submitter matches the
    /// uploader identity.
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
