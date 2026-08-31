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
public struct ChangelogSubscriptionResult: Codable, Equatable, Sendable {
    /// The address is now subscribed.
    public let subscribed: Bool
    /// The address was already on the list, so nothing changed.
    public let alreadySubscribed: Bool
}

/// Result of `POST /api/v1/public/apps/{appKey}/changelog/unsubscribe`.
public struct ChangelogUnsubscribeResult: Codable, Equatable, Sendable {
    /// The address was removed from the list.
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
        if httpResponse.statusCode != 200 {
            if httpResponse.statusCode == 401 {
                // Anonymous changelog disabled for this app.
                throw FeedbackClientError.authenticationRequired
            }
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw FeedbackClientError.unexpectedStatus(code: httpResponse.statusCode, message: message)
        }
        let result = try decoder.decode(ListChangelogResponse.self, from: data)
        return result.entries.sorted { lhs, rhs in
            (lhs.publishedAtDate ?? .distantPast) > (rhs.publishedAtDate ?? .distantPast)
        }
    }

    /// Subscribes an email address to changelog notifications.
    /// - Parameters:
    ///   - email: The address to notify. Trimmed before sending.
    ///   - userToken: Anonymous user token sent as `X-User-Token`, linking the
    ///     subscription to the end-user identity.
    /// - Returns: Whether the subscription was created or already existed.
    /// - Throws: ``FeedbackClientError/unexpectedStatus(code:message:)`` or
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

    /// Removes an email address from changelog notifications.
    /// - Parameter email: The address to unsubscribe. Trimmed before sending.
    /// - Returns: Whether the address was removed.
    /// - Throws: ``FeedbackClientError/unexpectedStatus(code:message:)`` or
    ///   ``FeedbackClientError/invalidResponse``.
    public func unsubscribeFromChangelog(email: String) async throws -> ChangelogUnsubscribeResult {
        try await send(
            "POST",
            path: "/api/v1/public/apps/\(configuration.appKey)/changelog/unsubscribe",
            body: ChangelogEmailPayload(email: email.trimmingCharacters(in: .whitespacesAndNewlines)),
            userToken: nil,
            acceptedStatuses: [200]
        )
    }

    /// Reports host-app revenue signals for the current end user.
    ///
    /// Host apps self-declare these attributes; the SDK never collects payment
    /// details. Omitted parameters are left unchanged server-side.
    /// - Parameters:
    ///   - isPaying: Whether the user is on a paid plan.
    ///   - plan: Host-app plan name (e.g. `"pro"`).
    ///   - mrr: Monthly recurring revenue attributable to this user.
    ///   - currency: Three-letter ISO 4217 code for `mrr` (the backend defaults to `"USD"`).
    ///   - userToken: Anonymous user token sent as `X-User-Token`.
    /// - Returns: Whether the update was applied and when.
    /// - Throws: ``FeedbackClientError/unexpectedStatus(code:message:)`` or
    ///   ``FeedbackClientError/invalidResponse``.
    public func updateUserAttributes(
        isPaying: Bool? = nil,
        plan: String? = nil,
        mrr: Double? = nil,
        currency: String? = nil,
        userToken: String
    ) async throws -> UserAttributesUpdateResult {
        try await send(
            "PUT",
            path: "/api/v1/public/apps/\(configuration.appKey)/user",
            body: UserAttributesPayload(isPaying: isPaying, plan: plan, mrr: mrr, currency: currency),
            userToken: userToken,
            acceptedStatuses: [200]
        )
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
        if let userToken {
            request.setValue(userToken, forHTTPHeaderField: "X-User-Token")
        }
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        if !acceptedStatuses.contains(httpResponse.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw FeedbackClientError.unexpectedStatus(code: httpResponse.statusCode, message: message)
        }
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
