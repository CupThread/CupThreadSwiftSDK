import Foundation

// MARK: - End-user self-service endpoints (/api/v1/me/*)

/// Result of `POST /api/v1/me/erase`.
public struct DataErasureResult: Codable, Equatable, Sendable {
    /// Whether the profile was erased. `false` when no profile matched the
    /// identity (e.g. replaying after a successful erase).
    public let erased: Bool
    /// The erased end-user profile id, when one existed.
    public let endUserId: String?
}

/// Result of `POST /api/v1/me/link`.
public struct EndUserLinkResult: Codable, Equatable, Sendable {
    /// Whether the profile was linked to the authenticated identity.
    public let linked: Bool
    /// The linked end-user profile id.
    public let endUserId: String?
    /// The authenticated (Clerk) user id the profile is now linked to.
    public let clerkUserId: String?
}

private struct MeAppKeyPayload: Encodable, Sendable {
    let appKey: String
}

extension FeedbackClient {

    /// Erases the calling end user's profile for this app (self-service data
    /// erasure).
    ///
    /// The anonymous token is rotated server-side — the old token stops
    /// working immediately — stored PII is removed, and the user's feature
    /// requests, votes, and comments are anonymized while aggregate counts
    /// are preserved.
    ///
    /// - Parameter userToken: Anonymous user token sent as `X-User-Token`.
    /// - Returns: Whether a profile was erased. A `404` from the server is
    ///   normalized to `erased: false` rather than an error, so replaying an
    ///   erase is idempotent from the caller's perspective.
    /// - Throws: ``FeedbackClientError/authenticationRequired`` when no
    ///   identity header is present, ``FeedbackClientError/rateLimited`` on
    ///   HTTP 429, or ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
    ///   / ``FeedbackClientError/invalidResponse``.
    public func eraseMyData(userToken: String) async throws -> DataErasureResult {
        var request = URLRequest(url: configuration.baseURL.appending(path: "/api/v1/me/erase"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyCorrelationHeaders(userToken: userToken, requestID: nextRequestID(), to: &request)
        request.httpBody = try encoder.encode(MeAppKeyPayload(appKey: configuration.appKey))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        if httpResponse.statusCode == 404 {
            // No profile matched the identity — nothing to erase.
            return DataErasureResult(erased: false, endUserId: nil)
        }
        try validateResponse(httpResponse, data: data, accepted: [200])
        return try decoder.decode(DataErasureResult.self, from: data)
    }

    /// Links the anonymous end-user profile to an authenticated user session
    /// (e.g. a social-login Clerk session token), for apps that let users
    /// transition from anonymous voting/feedback to authenticated accounts.
    ///
    /// - Parameters:
    ///   - sessionToken: The authenticated session token, sent as
    ///     `Authorization: Bearer <sessionToken>`.
    ///   - userToken: Anonymous user token sent as `X-User-Token`.
    /// - Returns: The confirmed link, including the authenticated identity.
    /// - Throws: ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
    ///   with status 401 when the session is missing, 404 when no profile
    ///   matches, and 409 when the profile is already confirmed to a
    ///   different identity, or ``FeedbackClientError/invalidResponse``.
    public func linkEndUser(
        sessionToken: String,
        userToken: String
    ) async throws -> EndUserLinkResult {
        var request = URLRequest(url: configuration.baseURL.appending(path: "/api/v1/me/link"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        applyCorrelationHeaders(userToken: userToken, requestID: nextRequestID(), to: &request)
        request.httpBody = try encoder.encode(MeAppKeyPayload(appKey: configuration.appKey))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        try validateResponse(httpResponse, data: data, accepted: [200])
        return try decoder.decode(EndUserLinkResult.self, from: data)
    }
}
