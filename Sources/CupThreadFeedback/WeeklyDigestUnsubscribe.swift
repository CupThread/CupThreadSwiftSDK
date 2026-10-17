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
    ///   Blank or whitespace-only values are rejected locally — the signed
    ///   token alone identifies the workspace and recipient, so dispatching
    ///   with `token=` can only come back rejected (#416).
    /// - Returns: Whether the address was removed from the weekly digest.
    /// - Throws: ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
    ///   (status 400 when the token is blank — rejected locally with no
    ///   network round trip and no server request id — or missing, invalid,
    ///   or expired on the server),
    ///   ``FeedbackClientError/authenticationRequired`` (HTTP 401),
    ///   ``FeedbackClientError/forbidden(message:requestId:)`` (HTTP 403),
    ///   ``FeedbackClientError/rateLimited`` on HTTP 429, or
    ///   ``FeedbackClientError/invalidResponse``.
    public func unsubscribeFromWeeklyDigest(
        token: String
    ) async throws -> WeeklyDigestUnsubscribeResult {
        // A blank token has no signature to verify and can only come back
        // rejected, so fail fast instead of dispatching the mutating POST
        // with `token=` (#416) — same contract as the changelog
        // unsubscribe sibling (#419).
        guard let trimmedToken = token.nilIfEmpty else {
            throw FeedbackClientError.unexpectedStatus(
                code: 400,
                message: "Unsubscribe token cannot be empty",
                requestId: nil
            )
        }
        let base = configuration.baseURL.appending(path: "/api/v1/public/digest/unsubscribe")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: true) else {
            throw FeedbackClientError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "token", value: trimmedToken)]
        guard let url = components.url else {
            throw FeedbackClientError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // The digest unsubscribe endpoint content-negotiates an HTML landing
        // page for browsers; the JSON result this method decodes is only
        // guaranteed with an explicit JSON preference.
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try applyCorrelationHeaders(userToken: nil, requestID: nextRequestID(), to: &request)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        // Map 401 (invalid/expired identity token) and 403 (public surfaces
        // or digest unsubscribes disabled) to typed permission errors (issue #372).
        try validateResponse(httpResponse, data: data, accepted: [200], mapsPermissionErrors: true)
        return try decodeSuccess(WeeklyDigestUnsubscribeResult.self, from: data)
    }
}
