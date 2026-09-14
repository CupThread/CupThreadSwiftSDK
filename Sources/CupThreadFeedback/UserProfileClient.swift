import Foundation

// MARK: - FeedbackClient extension

extension FeedbackClient {

    /// Fetches the public profile for a given user.
    /// - Parameter userId: The Clerk user id of the profile to fetch.
    /// - Returns: The user's public profile data.
    /// - Throws: ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
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
        try validateResponse(httpResponse, data: data, accepted: [200])
        return try decoder.decode(PublicUserProfileResponse.self, from: data)
    }
}
