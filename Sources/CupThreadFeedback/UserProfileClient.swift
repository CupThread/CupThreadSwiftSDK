import Foundation

// MARK: - FeedbackClient extension

extension FeedbackClient {

    /// Fetches the public profile for a given user.
    /// - Parameter userId: App-scoped pseudonymous user identifier (as found
    ///   in `authorClerkId`, `replyToClerkId`, `requesterClerkId`, and
    ///   `recentCommenters[].clerkUserId` on public payloads); raw user IDs
    ///   are accepted as well. App-scoped ids (`u_…`) are looked up within
    ///   the configuration's app, so the request carries the `appKey` query
    ///   parameter the server requires for them. Profiles are opt-in:
    ///   callers should expect
    ///   ``FeedbackClientError/userProfileNotFound(message:)`` for unknown
    ///   identifiers and an empty profile for users without a public profile.
    /// - Returns: The user's public profile data.
    /// - Throws: ``FeedbackClientError/userProfileNotFound(message:)``,
    ///   ``FeedbackClientError/rateLimited(message:requestId:)`` when the
    ///   per-client-IP rate limit is spent (HTTP 429 — back off and retry),
    ///   ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``,
    ///   or ``FeedbackClientError/invalidResponse``.
    public func fetchUserProfile(userId: String) async throws -> PublicUserProfileResponse {
        var profileURL = configuration.baseURL.appending(path: "/api/v1/users/\(userId)/profile")
        // App-scoped public ids (`u_<32-hex>`) from board/comment payloads are
        // app-keyed on the server: without `appKey` an existing user answers
        // 404 "User profile not found". Raw Clerk ids (`user_*`, from /u/
        // bookmarks) remain accepted without it.
        if userId.hasPrefix("u_") {
            var components = URLComponents(
                url: profileURL,
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [URLQueryItem(name: "appKey", value: configuration.appKey)]
            if let keyedURL = components?.url {
                profileURL = keyedURL
            }
        }
        var request = URLRequest(url: profileURL)
        request.httpMethod = "GET"
        applyCorrelationHeaders(userToken: nil, requestID: nextRequestID(), to: &request)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        if httpResponse.statusCode == 404 {
            let envelope = try? decoder.decode(APIErrorEnvelope.self, from: data)
            let rawMessage = envelope?.error ?? String(data: data, encoding: .utf8)
            let trimmed = rawMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = (trimmed?.isEmpty ?? true) ? nil : trimmed
            throw FeedbackClientError.userProfileNotFound(message: message)
        }
        try validateResponse(httpResponse, data: data, accepted: [200])
        return try decoder.decode(PublicUserProfileResponse.self, from: data)
    }
}
