import Foundation

// MARK: - Changelog models (GET /api/v1/public/apps/{appKey}/changelog)

/// A published changelog entry, as returned by the public changelog endpoint.
///
/// `body` may contain inline Markdown;
/// ``WhatsNewView`` and ``ChangelogOverlayView`` render it with
/// bold/italic/code/link styling.
public struct ChangelogEntry: Codable, Identifiable, Equatable, Sendable {
    /// Stable entry id.
    public let id: String
    /// Entry headline.
    public let title: String
    /// Entry body; may contain inline Markdown.
    public let body: String
    /// Version badge text, e.g. `"2.1.0"`, when the entry is tied to a release.
    public let versionLabel: String?
    /// ISO-8601 publish timestamp as reported by the server.
    public let publishedAt: String
    /// Feature requests that shipped with this entry.
    public let linkedRequests: [ChangelogLinkedRequest]
}

/// A feature request that shipped with a changelog entry (id + title only).
public struct ChangelogLinkedRequest: Codable, Identifiable, Equatable, Sendable {
    /// Id of the shipped feature request.
    public let id: String
    /// Title shown on the "shipped" chip.
    public let title: String
}

struct ListChangelogResponse: Codable, Sendable {
    let entries: [ChangelogEntry]
}

// MARK: - Subscription / user-attribute results

/// Result of `POST /api/v1/public/apps/{appKey}/changelog/subscribe`.
///
/// Subscriptions are double opt-in: the address starts as pending and must
/// confirm via the single-use link in the confirmation email before it
/// receives changelog emails.
public struct ChangelogSubscriptionResult: Decodable, Equatable, Sendable {
    /// The subscription was recorded (pending confirmation).
    public let subscribed: Bool

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The API documented `{ "subscribed": true }`; the OpenAPI schema
        // names the field `success`. Accept both, defaulting to true so a
        // uniform 201 is treated as success.
        subscribed = try container.decodeIfPresent(Bool.self, forKey: .subscribed)
            ?? container.decodeIfPresent(Bool.self, forKey: .success)
            ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case subscribed, success
    }
}

/// Result of `POST /api/v1/public/apps/{appKey}/changelog/unsubscribe`.
public struct ChangelogUnsubscribeResult: Codable, Equatable, Sendable {
    /// The address was removed from the list (uniform whether or not the
    /// subscription existed).
    public let unsubscribed: Bool
}

/// Result of `PUT /api/v1/public/apps/{appKey}/user`.
public struct UserAttributesUpdateResult: Codable, Equatable, Sendable {
    /// Whether the update was applied.
    public let ok: Bool
    /// ISO-8601 timestamp of the write, as reported by the server.
    public let updatedAt: String
}

// MARK: - Private payloads

private struct ChangelogEmailPayload: Encodable, Sendable {
    let email: String
}

private struct UserAttributesPayload: Encodable, Sendable {
    let isPaying: Bool?
    let plan: String?
    let mrr: Double?
    let currency: String?
    let signature: String?
    let timestamp: Int64?
}

// MARK: - FeedbackClient extension

extension FeedbackClient {

    /// Fetches the published changelog for the configured app, sorted newest-first.
    ///
    /// Throws `FeedbackClientError.authenticationRequired` when the app has
    /// disabled anonymous changelog access; unknown app keys surface as
    /// `.unexpectedStatus` with status 404.
    /// - Returns: All published entries, newest first.
    /// - Throws: ``FeedbackClientError/authenticationRequired`` when anonymous
    ///   changelog access is disabled, ``FeedbackClientError/unexpectedStatus(code:message:)``
    ///   for other HTTP failures, or ``FeedbackClientError/invalidResponse``.
    public func fetchChangelog() async throws -> [ChangelogEntry] {
        var request = URLRequest(
            url: configuration.baseURL.appending(path: "/api/v1/public/apps/\(configuration.appKey)/changelog")
        )
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        if httpResponse.statusCode == 401 {
            // Anonymous changelog disabled for this app.
            throw FeedbackClientError.authenticationRequired
        }
        try validateResponse(httpResponse, data: data, accepted: [200])
        let result = try decoder.decode(ListChangelogResponse.self, from: data)
        return result.entries.sorted { lhs, rhs in
            (lhs.publishedAtDate ?? .distantPast) > (rhs.publishedAtDate ?? .distantPast)
        }
    }

    /// Subscribes an email address to changelog notifications.
    ///
    /// Subscriptions are double opt-in: the address starts as pending and
    /// receives a confirmation email with a single-use link; only confirmed
    /// subscriptions receive changelog emails. The response is uniform — the
    /// API no longer reports whether the address was already subscribed.
    /// - Parameters:
    ///   - email: The address to notify. Trimmed before sending.
    ///   - userToken: Anonymous user token sent as `X-User-Token`, linking the
    ///     subscription to the end-user identity.
    /// - Returns: Whether the subscription was recorded (pending confirmation).
    /// - Throws: ``FeedbackClientError/rateLimited`` on HTTP 429,
    ///   ``FeedbackClientError/unexpectedStatus(code:message:requestId:)`` or
    ///   ``FeedbackClientError/invalidResponse``.
    public func subscribeToChangelog(
        email: String,
        userToken: String
    ) async throws -> ChangelogSubscriptionResult {
        try await send(
            "POST",
            path: "/api/v1/public/apps/\(configuration.appKey)/changelog/subscribe",
            body: ChangelogEmailPayload(email: email.trimmingCharacters(in: .whitespacesAndNewlines)),
            userToken: userToken,
            acceptedStatuses: [200, 201]
        )
    }

    /// Unsubscribes using the per-subscriber signed token carried by the
    /// unsubscribe link in every changelog or confirmation email.
    ///
    /// The API removed the unauthenticated bare-email unsubscribe; tokens are
    /// single-subscriber secrets delivered by email, so the SDK's own
    /// surfaces no longer offer in-app unsubscription.
    /// - Parameter token: The signed token from the unsubscribe link.
    /// - Returns: Whether the address was removed.
    /// - Throws: ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
    ///   (status 400 when the token is missing) or
    ///   ``FeedbackClientError/invalidResponse``.
    public func unsubscribeFromChangelog(token: String) async throws -> ChangelogUnsubscribeResult {
        let base = configuration.baseURL.appending(
            path: "/api/v1/public/apps/\(configuration.appKey)/changelog/unsubscribe"
        )
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: true) else {
            throw FeedbackClientError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else {
            throw FeedbackClientError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyCorrelationHeaders(userToken: nil, requestID: nextRequestID(), to: &request)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        try validateResponse(httpResponse, data: data, accepted: [200])
        return try decoder.decode(ChangelogUnsubscribeResult.self, from: data)
    }

    /// Reports host-app revenue signals for the current end user.
    ///
    /// Host apps self-declare these attributes; the SDK never collects payment
    /// details. Omitted parameters are left unchanged server-side.
    ///
    /// When reporting paying-user attributes (`isPaying`, `plan`, or `mrr`),
    /// the request must be HMAC-SHA256 signed using the app's SDK signing secret
    /// (configured on ``FeedbackClientConfiguration/signingSecret`` or provided
    /// via the `signingSecret` parameter). Requests without payment attributes
    /// (identity or `currency`-only updates) do not require a signature and are
    /// sent unsigned.
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
            isPaying: isPaying,
            plan: plan,
            mrr: mrr,
            currency: currency,
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
        let hasPaymentAttributes = isPaying != nil || plan != nil || mrr != nil
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
            return try await send(
                "PUT",
                path: "/api/v1/public/apps/\(configuration.appKey)/user",
                body: payload,
                userToken: userToken,
                acceptedStatuses: [200]
            )
        } catch FeedbackClientError.rateLimited {
            try await Task.sleep(for: .seconds(1))
            return try await send(
                "PUT",
                path: "/api/v1/public/apps/\(configuration.appKey)/user",
                body: payload,
                userToken: userToken,
                acceptedStatuses: [200]
            )
        }
    }

    /// Shared JSON request/response plumbing for the changelog endpoints.
    private func send<Response: Decodable>(
        _ method: String,
        path: String,
        body: some Encodable,
        userToken: String?,
        acceptedStatuses: Set<Int>
    ) async throws -> Response {
        var request = URLRequest(url: configuration.baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyCorrelationHeaders(userToken: userToken, requestID: nextRequestID(), to: &request)
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        try validateResponse(httpResponse, data: data, accepted: acceptedStatuses)
        return try decoder.decode(Response.self, from: data)
    }
}

// MARK: - Date helpers

extension ChangelogEntry {
    /// Parsed `publishedAt`, accepting plain and fractional-second ISO-8601.
    var publishedAtDate: Date? {
        if let date = try? Date(publishedAt, strategy: Self.fractionalISO) {
            return date
        }
        return try? Date(publishedAt, strategy: .iso8601)
    }

    private static let fractionalISO = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}
