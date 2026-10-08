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
    /// the request must be HMAC-SHA256 signed using the app's SDK signing secret
    /// (configured on ``FeedbackClientConfiguration/signingSecret`` or provided
    /// via the `signingSecret` parameter). Requests without payment attributes
    /// (identity-only updates) do not require a signature and are
    /// sent unsigned.
    ///
    /// To explicitly clear an attribute server-side (such as a churned subscription
    /// plan or reset MRR), pass `.null` using the ``UserAttributesSigner/Field`` overload.
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
    ///   - plan: Host-app plan name (e.g. `"pro"`).
    ///   - mrr: Monthly recurring revenue attributable to this user.
    ///   - currency: Three-letter ISO 4217 code for `mrr` (an omitted currency preserves the stored value).
    ///   - userToken: Anonymous user token sent as `X-User-Token`.
    ///   - signingSecret: Optional override for the SDK signing secret configured
    ///     on ``FeedbackClientConfiguration/signingSecret``.
    /// - Returns: Whether the update was applied and when.
    /// - Throws: ``FeedbackClientError/rateLimited`` when the retry is also
    ///   limited, ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``,
    ///   ``FeedbackClientError/invalidResponse``, or — for payment-attribute
    ///   reports — the signature failures
    ///   ``FeedbackClientError/paymentAttributesRequireSignature(message:requestId:)``,
    ///   ``FeedbackClientError/sdkSigningSecretNotConfigured(message:requestId:)``,
    ///   ``FeedbackClientError/invalidSignature(message:requestId:)``, and
    ///   ``FeedbackClientError/staleSignature(message:requestId:)``.
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
    /// - Parameters:
    ///   - isPaying: Whether the user is on a paid plan (`.value`, `.null`, or `.unset`).
    ///   - plan: Host-app plan name (`.value`, `.null`, or `.unset`).
    ///   - mrr: Monthly recurring revenue (`.value`, `.null`, or `.unset`).
    ///   - currency: Currency code (`.value`, `.null`, or `.unset`).
    ///   - userToken: Anonymous user token sent as `X-User-Token`.
    ///   - signingSecret: Optional override for the SDK signing secret configured
    ///     on ``FeedbackClientConfiguration/signingSecret``.
    /// - Returns: Whether the update was applied and when.
    /// - Throws: ``FeedbackClientError/rateLimited`` when the retry is also
    ///   limited, ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``,
    ///   ``FeedbackClientError/invalidResponse``, or — for payment-attribute
    ///   reports — the signature failures
    ///   ``FeedbackClientError/paymentAttributesRequireSignature(message:requestId:)``,
    ///   ``FeedbackClientError/sdkSigningSecretNotConfigured(message:requestId:)``,
    ///   ``FeedbackClientError/invalidSignature(message:requestId:)``, and
    ///   ``FeedbackClientError/staleSignature(message:requestId:)``.
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
    /// - Parameters:
    ///   - userToken: Anonymous user token sent as `X-User-Token`.
    ///   - signingSecret: Optional override for the SDK signing secret configured
    ///     on ``FeedbackClientConfiguration/signingSecret``.
    /// - Returns: Whether the update was applied and when.
    /// - Throws: ``FeedbackClientError/rateLimited`` when the retry is also
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
        let hasPaymentAttributes = isPaying != .unset || plan != .unset || mrr != .unset || currency != .unset

        func signedPayload(epochSeconds: Int64, secret: String) -> UserAttributesPayload {
            let canonical = UserAttributesSigner.canonicalString(
                for: .init(
                    appKey: configuration.appKey,
                    userToken: userToken,
                    isPaying: isPaying,
                    plan: plan,
                    mrr: mrr,
                    currency: currency,
                    timestamp: epochSeconds
                )
            )
            return UserAttributesPayload(
                isPaying: isPaying,
                plan: plan,
                mrr: mrr,
                currency: currency,
                signature: UserAttributesSigner.signature(for: canonical, secret: secret),
                timestamp: epochSeconds
            )
        }

        // The signing clock is the device clock corrected by the server-time
        // offset learned from response `Date` headers (API-19) — the pinned
        // `timestamp` test parameter wins when provided. Before any
        // observation the offset is 0, so behavior matches the device clock.
        let signingSecretInUse = (signingSecret ?? configuration.signingSecret)?.nilIfEmpty
        let payload: UserAttributesPayload
        if hasPaymentAttributes, let secret = signingSecretInUse {
            let epochSeconds = timestamp ?? Int64(serverClock.correctedNow().timeIntervalSince1970)
            payload = signedPayload(epochSeconds: epochSeconds, secret: secret)
        } else {
            payload = UserAttributesPayload(
                isPaying: isPaying,
                plan: plan,
                mrr: mrr,
                currency: currency
            )
        }

        do {
            return try await sendUserAttributesAttempt(payload, userToken: userToken)
        } catch let error as FeedbackClientError {
            guard case .staleSignature = error,
                  hasPaymentAttributes, let secret = signingSecretInUse else {
                throw error
            }
            // The signature timestamp fell outside the server's freshness
            // window (API-19): the failing response's `Date` header has
            // already refreshed the offset in `validateResponse`, so
            // re-signing with the corrected clock produces a timestamp inside
            // the window. Retried exactly once — `invalid_signature` (a
            // mismatched secret) and every other failure is never retried,
            // because time cannot fix it.
            let retryEpochSeconds = Int64(serverClock.correctedNow().timeIntervalSince1970)
            return try await sendUserAttributesAttempt(
                signedPayload(epochSeconds: retryEpochSeconds, secret: secret),
                userToken: userToken
            )
        }
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
