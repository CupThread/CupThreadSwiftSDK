// swiftlint:disable file_length
import Foundation

// MARK: - User Attributes API

/// Result of `PUT /api/v1/public/apps/{appKey}/user`.
public struct UserAttributesUpdateResult: Codable, Equatable, Sendable {
    /// Whether the update was applied.
    public let ok: Bool
    /// ISO-8601 timestamp of the write, as reported by the server.
    public let updatedAt: String
}

// MARK: - Payloads

struct UserAttributesPayload: Encodable, Sendable {
    let isPaying: UserAttributesSigner.Field<Bool>
    let plan: UserAttributesSigner.Field<String>
    let mrr: UserAttributesSigner.Field<Double>
    let currency: UserAttributesSigner.Field<String>
    let signature: String?
    let timestamp: Int64?

    enum CodingKeys: String, CodingKey {
        case isPaying
        case plan
        case mrr
        case currency
        case signature
        case timestamp
    }

    init(
        isPaying: UserAttributesSigner.Field<Bool> = .unset,
        plan: UserAttributesSigner.Field<String> = .unset,
        mrr: UserAttributesSigner.Field<Double> = .unset,
        currency: UserAttributesSigner.Field<String> = .unset,
        signature: String? = nil,
        timestamp: Int64? = nil
    ) {
        self.isPaying = isPaying
        self.plan = plan
        self.mrr = mrr
        self.currency = currency
        self.signature = signature
        self.timestamp = timestamp
    }

    init(
        isPaying: Bool? = nil,
        plan: String? = nil,
        mrr: Double? = nil,
        currency: String? = nil,
        signature: String? = nil,
        timestamp: Int64? = nil
    ) {
        self.init(
            isPaying: isPaying.map { .value($0) } ?? .unset,
            plan: plan.map { .value($0) } ?? .unset,
            mrr: mrr.map { .value($0) } ?? .unset,
            currency: currency.map { .value($0) } ?? .unset,
            signature: signature,
            timestamp: timestamp
        )
    }

    private func encodeField<T: Encodable>(
        _ field: UserAttributesSigner.Field<T>,
        forKey key: CodingKeys,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        switch field {
        case .unset:
            break
        case .null:
            try container.encodeNil(forKey: key)
        case .value(let value):
            try container.encode(value, forKey: key)
        }
    }

    /// Encodes a string attribute with the same CR/LF sanitization the
    /// canonical string applies (SEC-3). The server verifies the HMAC against
    /// the values it receives, so the wire value must be the sanitized line —
    /// sending the raw string would make every signed report carrying a
    /// newline in `plan`/`currency` fail signature verification.
    private func encodeTextField(
        _ field: UserAttributesSigner.Field<String>,
        forKey key: CodingKeys,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        switch field {
        case .unset:
            break
        case .null:
            try container.encodeNil(forKey: key)
        case .value(let value):
            try container.encode(UserAttributesSigner.sanitizedLine(value), forKey: key)
        }
    }

    /// Encodes a numeric attribute, coercing non-finite doubles to `0` (SEC-3):
    /// `JSONEncoder` refuses NaN/infinity outright, which would abort the whole
    /// update before any bytes reach the network, and
    /// ``UserAttributesSigner/canonicalNumber(_:)`` already renders those
    /// values as `"0"` for the signature.
    private func encodeFiniteNumberField(
        _ field: UserAttributesSigner.Field<Double>,
        forKey key: CodingKeys,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        switch field {
        case .unset:
            break
        case .null:
            try container.encodeNil(forKey: key)
        case .value(let value):
            try container.encode(value.isFinite ? value : 0, forKey: key)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encodeField(isPaying, forKey: .isPaying, into: &container)
        try encodeTextField(plan, forKey: .plan, into: &container)
        try encodeFiniteNumberField(mrr, forKey: .mrr, into: &container)
        try encodeTextField(currency, forKey: .currency, into: &container)
        try container.encodeIfPresent(signature, forKey: .signature)
        try container.encodeIfPresent(timestamp, forKey: .timestamp)
    }
}

typealias UserAttributesWirePayload = UserAttributesPayload

// MARK: - FeedbackClient User Attributes Extension

extension FeedbackClient {

    /// Reports end-user attributes (paying status, plan, MRR, currency) to
    /// `PUT /api/v1/public/apps/{appKey}/user`.
    ///
    /// When reporting paying-user attributes (`isPaying`, `plan`, `mrr`, or `currency`),
    /// the request must be HMAC-SHA256 signed. The signature is produced
    /// wherever the SDK signing secret lives: a backend-delegated
    /// `userAttributesSigner` provider (your server holds the secret — the
    /// recommended integration, SEC-19), the app-embedded secret (configured
    /// on ``FeedbackClientConfiguration/signingSecret`` or provided via the
    /// `signingSecret` parameter, consulted only when no provider is
    /// installed or the provider declines), and, when neither is available,
    /// the report is sent unsigned and rejected by the server. Requests
    /// without payment attributes (identity-only updates) do not require a
    /// signature and are sent unsigned.
    ///
    /// > Warning: An embedded signing secret is not tamper-resistant — anyone
    /// > who installs the app can extract it from the binary and forge
    /// > verified payment attributes for arbitrary end users. Prefer the
    /// > backend-delegated `userAttributesSigner` provider on
    /// > ``FeedbackClient/init(configuration:session:turnstileTokenProvider:authenticationProvider:userAttributesSigner:)``.
    ///
    /// To explicitly clear an attribute server-side (such as a churned subscription
    /// plan or reset MRR), pass `.null` using the ``UserAttributesSigner/Field`` overload.
    ///
    /// Two plan names are reserved: the byte-exact literals `"unset"` and
    /// `"null"` are the signature canonical string's "leave unchanged" /
    /// "clear" sentinels (issue #403), so the server rejects a report whose
    /// plan equals either literal with HTTP 400 `plan_reserved_sentinel`,
    /// surfaced as ``FeedbackClientError/reservedPlanValue(message:requestId:)``.
    /// Near-miss strings (`"UNSET"`, `"Unset"`, `"unsettled"`, `"nullify"`, …)
    /// remain valid plan names.
    ///
    /// Signature timestamps come from the device clock corrected by the
    /// server-time offset the client learns from response `Date` headers
    /// (API-19), so a device whose clock is off never signs with a timestamp
    /// outside the server's ±300 s freshness window. When the server still
    /// rejects a signature as stale (`401 stale_signature`), the client
    /// refreshes the offset from the failing response and re-signs with the
    /// corrected clock, retrying exactly once; an `invalid_signature` failure
    /// (a mismatched secret — time cannot fix it) is never retried.
    ///
    /// The endpoint is rate limited per client IP (60 requests/minute), so a
    /// single HTTP 429 is retried once after a short backoff — bursts of
    /// first-syncs behind one shared IP recover without caller changes.
    /// - Parameters:
    ///   - isPaying: Whether the user is on a paid plan.
    ///   - plan: Host-app plan name (e.g. `"pro"`); never the reserved literals
    ///     `"unset"` or `"null"`.
    ///   - mrr: Monthly recurring revenue attributable to this user.
    ///   - currency: Three-letter ISO 4217 code for `mrr` (an omitted currency preserves the stored value).
    ///   - userToken: Anonymous user token sent as `X-User-Token`. Blank,
    ///     whitespace-only, or multi-line values are rejected locally — a
    ///     blank token would leave the signed report without any identity,
    ///     and surrounding whitespace would desynchronize the HMAC from the
    ///     trimmed header (#417).
    ///   - signingSecret: Optional override for the SDK signing secret configured
    ///     on ``FeedbackClientConfiguration/signingSecret``. Consulted only
    ///     when no `userAttributesSigner` provider is installed or the
    ///     provider declines — and not tamper-resistant (see the warning
    ///     above): prefer backend-delegated signing.
    /// - Returns: Whether the update was applied and when.
    /// - Throws: ``FeedbackClientError/authenticationRequired`` when
    ///   `userToken` is blank, whitespace-only, or contains a newline (all
    ///   rejected before anything is signed or sent),
    ///   ``FeedbackClientError/rateLimited`` when the retry is also
    ///   limited, ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``,
    ///   ``FeedbackClientError/invalidResponse``, or — for payment-attribute
    ///   reports — the signature failures
    ///   ``FeedbackClientError/paymentAttributesRequireSignature(message:requestId:)``,
    ///   ``FeedbackClientError/sdkSigningSecretNotConfigured(message:requestId:)``,
    ///   ``FeedbackClientError/invalidSignature(message:requestId:)``,
    ///   ``FeedbackClientError/staleSignature(message:requestId:)``, and the
    ///   reserved-plan validation error
    ///   ``FeedbackClientError/reservedPlanValue(message:requestId:)``.
    public func updateUserAttributes(
        isPaying: Bool? = nil,
        plan: String? = nil,
        mrr: Double? = nil,
        currency: String? = nil,
        userToken: String,
        signingSecret: String? = nil
    ) async throws -> UserAttributesUpdateResult {
        try await updateUserAttributes(
            isPaying: isPaying.map { .value($0) } ?? .unset,
            plan: plan.map { .value($0) } ?? .unset,
            mrr: mrr.map { .value($0) } ?? .unset,
            currency: currency.map { .value($0) } ?? .unset,
            userToken: userToken,
            signingSecret: signingSecret,
            timestamp: nil
        )
    }

    /// Reports end-user attributes with explicit tri-state fields (`unset`, `null`, `value`) to
    /// `PUT /api/v1/public/apps/{appKey}/user`.
    ///
    /// Use this overload to pass `.null` when clearing churned subscription plans or
    /// resetting MRR on the server.
    ///
    /// A `plan` of `.value("unset")` or `.value("null")` is rejected by the
    /// server with HTTP 400 `plan_reserved_sentinel` (issue #403) — those
    /// byte-exact literals are the canonical string's sentinels for `.unset`
    /// and `.null` — and surfaces as
    /// ``FeedbackClientError/reservedPlanValue(message:requestId:)``. Pass
    /// `.unset` / `.null` directly for the sentinel semantics.
    ///
    /// Signatures resolve exactly as in the optional-values overload: the
    /// backend-delegated `userAttributesSigner` provider first, then the
    /// embedded secret, then unsigned.
    ///
    /// > Warning: An embedded signing secret is not tamper-resistant — anyone
    /// > who installs the app can extract it from the binary and forge
    /// > verified payment attributes for arbitrary end users. Prefer the
    /// > backend-delegated `userAttributesSigner` provider on
    /// > ``FeedbackClient/init(configuration:session:turnstileTokenProvider:authenticationProvider:userAttributesSigner:)``.
    ///
    /// - Parameters:
    ///   - isPaying: Whether the user is on a paid plan (`.value`, `.null`, or `.unset`).
    ///   - plan: Host-app plan name (`.value`, `.null`, or `.unset`); a `.value`
    ///     is never the reserved literals `"unset"` or `"null"`.
    ///   - mrr: Monthly recurring revenue (`.value`, `.null`, or `.unset`).
    ///   - currency: Currency code (`.value`, `.null`, or `.unset`).
    ///   - userToken: Anonymous user token sent as `X-User-Token`. Blank,
    ///     whitespace-only, or multi-line values are rejected locally (#417).
    ///   - signingSecret: Optional override for the SDK signing secret configured
    ///     on ``FeedbackClientConfiguration/signingSecret``. Consulted only
    ///     when no `userAttributesSigner` provider is installed or the
    ///     provider declines.
    /// - Returns: Whether the update was applied and when.
    /// - Throws: ``FeedbackClientError/authenticationRequired`` when
    ///   `userToken` is blank, whitespace-only, or contains a newline (all
    ///   rejected before anything is signed or sent),
    ///   ``FeedbackClientError/rateLimited`` when the retry is also
    ///   limited, ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``,
    ///   ``FeedbackClientError/invalidResponse``, or — for payment-attribute
    ///   reports — the signature failures
    ///   ``FeedbackClientError/paymentAttributesRequireSignature(message:requestId:)``,
    ///   ``FeedbackClientError/sdkSigningSecretNotConfigured(message:requestId:)``,
    ///   ``FeedbackClientError/invalidSignature(message:requestId:)``,
    ///   ``FeedbackClientError/staleSignature(message:requestId:)``, and the
    ///   reserved-plan validation error
    ///   ``FeedbackClientError/reservedPlanValue(message:requestId:)``.
    public func updateUserAttributes(
        isPaying: UserAttributesSigner.Field<Bool> = .unset,
        plan: UserAttributesSigner.Field<String> = .unset,
        mrr: UserAttributesSigner.Field<Double> = .unset,
        currency: UserAttributesSigner.Field<String> = .unset,
        userToken: String,
        signingSecret: String? = nil
    ) async throws -> UserAttributesUpdateResult {
        try await updateUserAttributes(
            isPaying: isPaying,
            plan: plan,
            mrr: mrr,
            currency: currency,
            userToken: userToken,
            signingSecret: signingSecret,
            timestamp: nil
        )
    }

    /// Reports end-user attributes (identity only) to `PUT /api/v1/public/apps/{appKey}/user`.
    ///
    /// Identity-only reports carry no payment attributes and are sent
    /// unsigned, so no signing secret or signing provider is consulted.
    ///
    /// > Warning: The `signingSecret` override accepted here for signature
    /// > symmetry is never used by this overload — and an embedded signing
    /// > secret anywhere in a host app is not tamper-resistant: anyone who
    /// > installs the app can extract it from the binary and forge verified
    /// > payment attributes. Prefer the backend-delegated `userAttributesSigner`
    /// > provider on ``FeedbackClient/init(configuration:session:turnstileTokenProvider:authenticationProvider:userAttributesSigner:)``.
    ///
    /// - Parameters:
    ///   - userToken: Anonymous user token sent as `X-User-Token`. Blank,
    ///     whitespace-only, or multi-line values are rejected locally (#417).
    ///   - signingSecret: Optional override for the SDK signing secret configured
    ///     on ``FeedbackClientConfiguration/signingSecret``. Unused by this
    ///     identity-only overload — no payment attributes, no signature.
    /// - Returns: Whether the update was applied and when.
    /// - Throws: ``FeedbackClientError/authenticationRequired`` when
    ///   `userToken` is blank, whitespace-only, or contains a newline (all
    ///   rejected before anything is signed or sent),
    ///   ``FeedbackClientError/rateLimited`` when the retry is also
    ///   limited, ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``,
    ///   ``FeedbackClientError/invalidResponse``, or — for payment-attribute
    ///   reports — the signature failures
    ///   ``FeedbackClientError/paymentAttributesRequireSignature(message:requestId:)``,
    ///   ``FeedbackClientError/sdkSigningSecretNotConfigured(message:requestId:)``,
    ///   ``FeedbackClientError/invalidSignature(message:requestId:)``, and
    ///   ``FeedbackClientError/staleSignature(message:requestId:)``.
    public func updateUserAttributes(
        userToken: String,
        signingSecret: String? = nil
    ) async throws -> UserAttributesUpdateResult {
        try await updateUserAttributes(
            isPaying: .unset,
            plan: .unset,
            mrr: .unset,
            currency: .unset,
            userToken: userToken,
            signingSecret: signingSecret,
            timestamp: nil
        )
    }

    func updateUserAttributes(
        isPaying: Bool? = nil,
        plan: String? = nil,
        mrr: Double? = nil,
        currency: String? = nil,
        userToken: String,
        signingSecret: String? = nil,
        timestamp: Int64? = nil
    ) async throws -> UserAttributesUpdateResult {
        try await updateUserAttributes(
            isPaying: isPaying.map { .value($0) } ?? .unset,
            plan: plan.map { .value($0) } ?? .unset,
            mrr: mrr.map { .value($0) } ?? .unset,
            currency: currency.map { .value($0) } ?? .unset,
            userToken: userToken,
            signingSecret: signingSecret,
            timestamp: timestamp
        )
    }

    func updateUserAttributes(
        isPaying: UserAttributesSigner.Field<Bool> = .unset,
        plan: UserAttributesSigner.Field<String> = .unset,
        mrr: UserAttributesSigner.Field<Double> = .unset,
        currency: UserAttributesSigner.Field<String> = .unset,
        userToken: String,
        signingSecret: String? = nil,
        timestamp: Int64? = nil
    ) async throws -> UserAttributesUpdateResult {
        // A blank token would be silently dropped by applyUserToken, putting
        // a signed payload on the wire with no identity at all; a token with
        // surrounding whitespace would be signed un-trimmed but sent
        // trimmed, desynchronizing the HMAC from the `X-User-Token` header
        // the server verifies; a newline-containing token can never be sent
        // as a header value. Fail fast before anything is signed or sent
        // (#417) — the trimmed token is used for both the canonical string
        // and the header so the signature always matches.
        let identityToken = try validatedUserToken(userToken)
        let signingSecretInUse = (signingSecret ?? configuration.signingSecret)?.nilIfEmpty

        // The signing clock is the device clock corrected by the server-time
        // offset learned from response `Date` headers (API-19) — the pinned
        // `timestamp` test parameter wins when provided. Before any
        // observation the offset is 0, so behavior matches the device clock.
        let initialEpochSeconds = timestamp ?? Int64(serverClock.correctedNow().timeIntervalSince1970)
        let attempt = try await resolveUserAttributesAttemptPayload(
            arguments: UserAttributesSigner.Arguments(
                appKey: configuration.appKey,
                userToken: identityToken,
                isPaying: isPaying,
                plan: plan,
                mrr: mrr,
                currency: currency,
                timestamp: initialEpochSeconds
            ),
            signingSecretInUse: signingSecretInUse
        )

        do {
            return try await sendUserAttributesAttempt(attempt.payload, userToken: identityToken)
        } catch let error as FeedbackClientError {
            guard case .staleSignature = error, attempt.signed else {
                throw error
            }
            // The signature timestamp fell outside the server's freshness
            // window (API-19): the failing response's `Date` header has
            // already refreshed the offset in `validateResponse`, so a fresh
            // timestamp from the corrected clock lands inside the window.
            // Resolution runs again with the fresh timestamp — the provider
            // is called once more, falling back to the secret when it
            // declines — and the PUT is retried exactly once. An
            // `invalid_signature` failure (a mismatched secret — time cannot
            // fix it) and every other failure is never retried.
            let retryEpochSeconds = Int64(serverClock.correctedNow().timeIntervalSince1970)
            let retry = try await resolveUserAttributesAttemptPayload(
                arguments: UserAttributesSigner.Arguments(
                    appKey: configuration.appKey,
                    userToken: identityToken,
                    isPaying: isPaying,
                    plan: plan,
                    mrr: mrr,
                    currency: currency,
                    timestamp: retryEpochSeconds
                ),
                signingSecretInUse: signingSecretInUse
            )
            return try await sendUserAttributesAttempt(retry.payload, userToken: identityToken)
        }
    }

    /// Produces the payload for one signed-or-unsigned `PUT /user` attempt.
    ///
    /// Signing resolution (SEC-19): the backend-delegated provider wins,
    /// then the embedded secret, then the report goes unsigned (which the
    /// server rejects). The SDK builds the canonical string with its own
    /// server-clock-corrected timestamp (embedded in `arguments`) and sends
    /// the provider's returned timestamp verbatim; a provider result outside
    /// the signature grammar is rejected locally before any request is
    /// built. The `signed` flag tells the stale-signature retry whether this
    /// attempt carried a signature worth refreshing.
    private func resolveUserAttributesAttemptPayload(
        arguments: UserAttributesSigner.Arguments,
        signingSecretInUse: String?
    ) async throws -> (payload: UserAttributesPayload, signed: Bool) {
        func payload(signature: String?, timestamp: Int64?) -> UserAttributesPayload {
            UserAttributesPayload(
                isPaying: arguments.isPaying,
                plan: arguments.plan,
                mrr: arguments.mrr,
                currency: arguments.currency,
                signature: signature,
                timestamp: timestamp
            )
        }

        guard arguments.isPaying != .unset || arguments.plan != .unset
                || arguments.mrr != .unset || arguments.currency != .unset else {
            return (payload(signature: nil, timestamp: nil), false)
        }
        let request = UserAttributesSigningRequest(
            canonicalString: UserAttributesSigner.canonicalString(for: arguments),
            arguments: arguments
        )
        if let provider = userAttributesSigner {
            if let resolved = try await provider(request) {
                guard UserAttributesSignatureGrammar.isValid(resolved.signature) else {
                    throw FeedbackClientError.invalidSignature(
                        message: "Signing provider returned a malformed signature (expected 64 hexadecimal characters)",
                        requestId: nil
                    )
                }
                return (payload(signature: resolved.signature, timestamp: resolved.timestamp), true)
            }
        }
        if let secret = signingSecretInUse {
            let signature = UserAttributesSigner.signature(for: request.canonicalString, secret: secret)
            return (payload(signature: signature, timestamp: arguments.timestamp), true)
        }
        return (payload(signature: nil, timestamp: nil), false)
    }

    /// Sends one signed-or-unsigned `PUT /user` attempt, applying the
    /// endpoint's single HTTP 429 retry (same payload, after a short backoff).
    private func sendUserAttributesAttempt(
        _ payload: UserAttributesPayload,
        userToken: String
    ) async throws -> UserAttributesUpdateResult {
        do {
            return try await sendJSON(
                "PUT",
                path: "/api/v1/public/apps/\(configuration.appKey)/user",
                body: payload,
                userToken: userToken,
                acceptedStatuses: [200]
            )
        } catch FeedbackClientError.rateLimited {
            try await Task.sleep(for: .seconds(1))
            return try await sendJSON(
                "PUT",
                path: "/api/v1/public/apps/\(configuration.appKey)/user",
                body: payload,
                userToken: userToken,
                acceptedStatuses: [200]
            )
        }
    }
}
