import Foundation

// MARK: - Private payload types

/// The canonical wire payload for comment creation. The server schema
/// accepts exactly `body`, `parentId`, and `replyToAuthorName` — optional
/// fields must be **omitted**, never encoded as `null`. Author identity and
/// avatar resolve server-side from the signed-in profile, and reply
/// metadata (`replyToClerkId`) is derived from the parent comment, so the
/// matching `CommentDraft` fields are never sent.
private struct CommentSubmitPayload: Encodable, Sendable {
    let body: String
    let parentId: String?
    let replyToAuthorName: String?
}

/// Success envelope for comment creation: `201` with
/// `{"comment": FeatureRequestComment}`.
private struct CreatedCommentResponse: Decodable, Sendable {
    let comment: FeatureRequestComment
}

// MARK: - FeedbackClient extension

extension FeedbackClient {

    /// Fetches all public comments for a feature request.
    /// - Parameter featureRequestId: Id of the feature request.
    /// - Returns: The list of comments for the given feature request.
    /// - Throws: ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
    ///   or ``FeedbackClientError/invalidResponse``.
    public func fetchComments(featureRequestId: String) async throws -> [FeatureRequestComment] {
        var request = URLRequest(
            url: configuration.baseURL.appending(path: "/api/v1/feature-requests/\(featureRequestId)/comments")
        )
        request.httpMethod = "GET"
        applyCorrelationHeaders(userToken: nil, requestID: nextRequestID(), to: &request)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        try validateResponse(httpResponse, data: data, accepted: [200])
        let result = try decoder.decode(ListCommentsResponse.self, from: data)
        return result.comments
    }

    /// Submits a new comment on a feature request.
    ///
    /// Comment creation is signed-in-only: the server requires a Clerk
    /// session and answers `401 authentication_required` for anonymous
    /// callers. Create the client with an authentication provider
    /// (`FeedbackClient/init(configuration:session:authenticationProvider:)`)
    /// so the SDK can present `Authorization: Bearer …`; without one (or
    /// when the provider resolves `nil`), the request is sent anonymously
    /// and this method throws
    /// ``FeedbackClientError/authenticationRequired``. The anonymous
    /// `X-User-Token` correlation header is still sent. The author display
    /// name and avatar always resolve server-side from the signed-in
    /// profile, and reply metadata is derived from the parent comment, so
    /// the draft's author fields and `replyToClerkId` are not transmitted.
    /// - Parameters:
    ///   - featureRequestId: Id of the feature request to comment on.
    ///   - draft: The comment content and reply target. See ``CommentDraft``.
    ///   - userToken: A stable UUID string identifying the commenting user.
    /// - Returns: The created comment, as echoed by the server.
    /// - Throws: ``FeedbackClientError/authenticationRequired`` when the
    ///   caller is not signed in,
    ///   ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
    ///   or ``FeedbackClientError/invalidResponse`` otherwise.
    public func postComment(
        featureRequestId: String,
        draft: CommentDraft,
        userToken: String
    ) async throws -> FeatureRequestComment {
        let payload = CommentSubmitPayload(
            body: draft.body.trimmingCharacters(in: .whitespacesAndNewlines),
            parentId: draft.parentId,
            replyToAuthorName: draft.replyToAuthorName
        )

        var request = URLRequest(url: configuration.baseURL.appending(path: "/api/v1/feature-requests/\(featureRequestId)/comments"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyCorrelationHeaders(userToken: userToken, requestID: nextRequestID(), to: &request)
        await applyBearerToken(to: &request)
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        try validateResponse(httpResponse, data: data, accepted: [200, 201])
        return try decoder.decode(CreatedCommentResponse.self, from: data).comment
    }
}
