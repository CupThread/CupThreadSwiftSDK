import Foundation

// MARK: - FeedbackClient extension

extension FeedbackClient {

    /// Fetches the public profile for a given user.
    ///
    /// When configured with an authentication provider, the signed-in user's
    /// bearer token is attached as `Authorization: Bearer …` so profiles
    /// load when `allowAnonymousRoadmap = false`.
    /// - Parameter userId: App-scoped pseudonymous user identifier (as found
    ///   in `authorClerkId`, `replyToClerkId`, `requesterClerkId`, and
    ///   `recentCommenters[].clerkUserId` on public payloads); raw user IDs
    ///   are accepted as well. App-scoped ids (`u_…`) are looked up within
    ///   the configuration's app, so the request carries the `appKey` query
    ///   parameter the server requires for them. The value is trimmed, and
    ///   values that cannot be a single URL path segment (empty, whitespace,
    ///   or containing path/query/percent characters — API-26 grammar) throw
    ///   ``FeedbackClientError/userProfileNotFound(message:requestId:)``
    ///   locally, before any request is sent. Profiles are opt-in:
    ///   callers should expect
    ///   ``FeedbackClientError/userProfileNotFound(message:requestId:)`` for
    ///   unknown identifiers and an empty profile for users without a public
    ///   profile.
    /// - Returns: The user's public profile data.
    /// - Throws: ``FeedbackClientError/userProfileNotFound(message:requestId:)``
    ///   when the server answers HTTP 404 with the documented JSON error
    ///   envelope (the user has no public profile), or locally with no
    ///   request sent when `userId` cannot be a valid id,
    ///   ``FeedbackClientError/authenticationRequired`` or
    ///   ``FeedbackClientError/forbidden(message:requestId:)`` when
    ///   access is rejected by the server's permission policy (HTTP 401/403),
    ///   ``FeedbackClientError/rateLimited(message:requestId:)`` when the
    ///   per-client-IP rate limit is spent (HTTP 429 — back off and retry),
    ///   ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``,
    ///   or ``FeedbackClientError/invalidResponse``.
    public func fetchUserProfile(userId: String) async throws -> PublicUserProfileResponse {
        let trimmedID = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UserProfileIDGrammar.isValid(trimmedID) else {
            // An id that cannot be a single opaque path segment (API-26) can
            // never name an existing user, and interpolating it would alter
            // the route while carrying the caller's Authorization header —
            // refuse locally, before any request is built. Same convention
            // as `fetchFeatureRequest` and the vote endpoints: report
            // not-found.
            throw FeedbackClientError.userProfileNotFound(message: nil, requestId: nil)
        }
        var profileURL = configuration.baseURL.appending(path: "/api/v1/users/\(trimmedID)/profile")
        // App-scoped public ids (`u_<32-hex>`) from board/comment payloads are
        // app-keyed on the server: without `appKey` an existing user answers
        // 404 "User profile not found". Raw Clerk ids (`user_*`, from /u/
        // bookmarks) remain accepted without it.
        if trimmedID.hasPrefix("u_") {
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
        try applyCorrelationHeaders(userToken: nil, requestID: nextRequestID(), to: &request)
        await applyBearerToken(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        // A 404 means "no public profile" only when the body is the API's
        // documented JSON error envelope (API-26); router-, proxy-, and
        // captive-portal-fallback 404s fall through to `validateResponse`
        // and surface as `.unexpectedStatus` instead.
        try validateResponse(
            httpResponse,
            data: data,
            accepted: [200],
            mapsPermissionErrors: true,
            mapResourceNotFound: {
                FeedbackClientError.userProfileNotFound(message: $0, requestId: $1)
            }
        )
        do {
            return try decoder.decode(PublicUserProfileResponse.self, from: data)
        } catch is DecodingError {
            // A 200 with an unexpected or malformed payload is a transport/
            // server contract failure, not profile data — never leak the raw
            // `DecodingError` (API-26).
            throw FeedbackClientError.invalidResponse
        }
    }
}
