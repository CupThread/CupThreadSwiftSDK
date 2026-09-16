import Foundation

// MARK: - FeedbackClient extension

extension FeedbackClient {

    /// Fetches the public profile for a given user.
    /// - Parameter userId: App-scoped pseudonymous user identifier (as found
    ///   in `authorClerkId`, `replyToClerkId`, `requesterClerkId`, and
    ///   `recentCommenters[].clerkUserId` on public payloads); raw user IDs
    ///   are accepted as well. Profiles are opt-in: callers should expect
    ///   ``FeedbackClientError/userProfileNotFound(message:)`` for unknown
    ///   identifiers and an empty profile for users without a public profile.
    /// - Returns: The user's public profile data.
    /// - Throws: ``FeedbackClientError/userProfileNotFound(message:)``,
    ///   ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``,
    ///   or ``FeedbackClientError/invalidResponse``.
    public func fetchUserProfile(userId: String) async throws -> PublicUserProfileResponse {
        var request = URLRequest(
            url: configuration.baseURL.appending(path: "/api/v1/users/\(userId)/profile")
        )
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
