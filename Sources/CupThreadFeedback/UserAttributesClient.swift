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

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encodeField(isPaying, forKey: .isPaying, into: &container)
        try encodeField(plan, forKey: .plan, into: &container)
        try encodeField(mrr, forKey: .mrr, into: &container)
        try encodeField(currency, forKey: .currency, into: &container)
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
    /// When reporting paying-user attributes (`isPaying`, `plan`, or `mrr`),
    /// the request must be HMAC-SHA256 signed using the app's SDK signing secret
    /// (configured on ``FeedbackClientConfiguration/signingSecret`` or provided
    /// via the `signingSecret` parameter). Requests without payment attributes
    /// (identity or `currency`-only updates) do not require a signature and are
    /// sent unsigned.
    ///
    /// To explicitly clear an attribute server-side (such as a churned subscription
    /// plan or reset MRR), pass `.null` using the ``UserAttributesSigner/Field`` overload.
    ///
    /// The endpoint is rate limited per client IP (60 requests/minute), so a
    /// single HTTP 429 is retried once after a short backoff — bursts of
    /// first-syncs behind one shared IP recover without caller changes.
    /// - Parameters:
    ///   - isPaying: Whether the user is on a paid plan.
    ///   - plan: Host-app plan name (e.g. `"pro"`).
    ///   - mrr: Monthly recurring revenue attributable to this user.
    ///   - currency: Three-letter ISO 4217 code for `mrr` (the backend defaults to `"USD"`).
    ///   - userToken: Anonymous user token sent as `X-User-Token`.
    ///   - signingSecret: Optional override for the SDK signing secret configured
    ///     on ``FeedbackClientConfiguration/signingSecret``.
    /// - Returns: Whether the update was applied and when.
    /// - Throws: ``FeedbackClientError/rateLimited`` when the retry is also
    ///   limited, ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
    ///   or ``FeedbackClientError/invalidResponse``.
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
    ///   limited, ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
    ///   or ``FeedbackClientError/invalidResponse``.
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
    ///   limited, ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
    ///   or ``FeedbackClientError/invalidResponse``.
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
        let hasPaymentAttributes = isPaying != .unset || plan != .unset || mrr != .unset
        let signature: String?
        let effectiveTimestamp: Int64?

        if hasPaymentAttributes, let secret = (signingSecret ?? configuration.signingSecret)?.nilIfEmpty {
            let epochSeconds = timestamp ?? Int64(Date().timeIntervalSince1970)
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
            signature = UserAttributesSigner.signature(for: canonical, secret: secret)
            effectiveTimestamp = epochSeconds
        } else {
            signature = nil
            effectiveTimestamp = nil
        }

        let payload = UserAttributesPayload(
            isPaying: isPaying,
            plan: plan,
            mrr: mrr,
            currency: currency,
            signature: signature,
            timestamp: effectiveTimestamp
        )

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
