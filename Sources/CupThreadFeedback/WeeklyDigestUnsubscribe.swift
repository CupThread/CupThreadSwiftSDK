import Foundation

// MARK: - Weekly digest unsubscribe (POST /api/v1/public/digest/unsubscribe)

/// Result of `POST /api/v1/public/digest/unsubscribe` (weekly digest).
///
/// The digest endpoint returns the same `{ "unsubscribed": true }` shape as
/// the changelog unsubscribe, and replay is idempotent: the same `200`
/// whether or not this call performed the removal.
public typealias WeeklyDigestUnsubscribeResult = ChangelogUnsubscribeResult

extension FeedbackClient {
    /// Unsubscribes using the signed token carried by the `List-Unsubscribe`
    /// header and footer link of weekly digest emails.
    ///
    /// The weekly digest shares the changelog email's RFC 8058 protections:
    /// POST is the only mutating path — the GET form renders a
    /// non-destructive HTML confirmation page (JSON-only clients receive
    /// `405 Method Not Allowed`), so mail-gateway URL scanners that follow
    /// links never change notification preferences — and replaying the same
    /// token is idempotent. Unsubscribing clears only the workspace
    /// `weekly.digest` email event; inbox notifications are unchanged. The
    /// token is sent as the `token` query item (the RFC 8058 one-click form)
    /// and `Accept: application/json` is pinned because the endpoint
    /// content-negotiates an HTML landing page for browser form submissions.
    ///
    /// The digest endpoint is not app-scoped: the signed token alone
    /// identifies the workspace and recipient, so this method — unlike the
    /// changelog unsubscribe — does not append the configured app key.
    /// - Parameter token: The signed token from the digest unsubscribe link.
    /// - Returns: Whether the address was removed from the weekly digest.
    /// - Throws: ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
    ///   (status 400 when the token is missing, invalid, or expired),
    ///   ``FeedbackClientError/rateLimited`` on HTTP 429, or
    ///   ``FeedbackClientError/invalidResponse``.
    public func unsubscribeFromWeeklyDigest(
        token: String
    ) async throws -> WeeklyDigestUnsubscribeResult {
        let base = configuration.baseURL.appending(path: "/api/v1/public/digest/unsubscribe")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: true) else {
            throw FeedbackClientError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else {
            throw FeedbackClientError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // The digest unsubscribe endpoint content-negotiates an HTML landing
        // page for browsers; the JSON result this method decodes is only
        // guaranteed with an explicit JSON preference.
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyCorrelationHeaders(userToken: nil, requestID: nextRequestID(), to: &request)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        try validateResponse(httpResponse, data: data, accepted: [200])
        return try decoder.decode(WeeklyDigestUnsubscribeResult.self, from: data)
    }
}
