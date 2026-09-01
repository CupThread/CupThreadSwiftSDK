import Foundation

// MARK: - Private payload types

private struct CommentSubmitPayload: Encodable, Sendable {
    let body: String
    let authorName: String?
    let authorEmail: String?
    let authorAvatarUrl: String?
    let parentId: String?
    let replyToClerkId: String?
    let replyToAuthorName: String?
}

// MARK: - FeedbackClient extension

extension FeedbackClient {

    /// Fetches all public comments for a feature request.
    /// - Parameter featureRequestId: Id of the feature request.
    /// - Returns: The list of comments for the given feature request.
    /// - Throws: ``FeedbackClientError/unexpectedStatus(code:message:)`` or
    ///   ``FeedbackClientError/invalidResponse``.
    public func fetchComments(featureRequestId: String) async throws -> [FeatureRequestComment] {
        var request = URLRequest(
            url: configuration.baseURL.appending(path: "/api/v1/feature-requests/\(featureRequestId)/comments")
        )
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        if httpResponse.statusCode != 200 {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw FeedbackClientError.unexpectedStatus(code: httpResponse.statusCode, message: message)
        }
        let result = try decoder.decode(ListCommentsResponse.self, from: data)
        return result.comments
    }

    /// Submits a new comment on a feature request.
    /// - Parameters:
    ///   - featureRequestId: Id of the feature request to comment on.
    ///   - draft: The comment content and metadata.
    ///   - userToken: A stable UUID string identifying the commenting user.
    /// - Returns: The created comment.
    /// - Throws: ``FeedbackClientError/unexpectedStatus(code:message:)`` or
    ///   ``FeedbackClientError/invalidResponse``.
    public func postComment(
        featureRequestId: String,
        draft: CommentDraft,
        userToken: String
    ) async throws -> FeatureRequestComment {
        let payload = CommentSubmitPayload(
            body: draft.body.trimmingCharacters(in: .whitespacesAndNewlines),
            authorName: draft.authorName.nilIfEmpty,
            authorEmail: draft.authorEmail.nilIfEmpty,
            authorAvatarUrl: draft.authorAvatarUrl.nilIfEmpty,
            parentId: draft.parentId,
            replyToClerkId: draft.replyToClerkId,
            replyToAuthorName: draft.replyToAuthorName
        )

        var request = URLRequest(url: configuration.baseURL.appending(path: "/api/v1/feature-requests/\(featureRequestId)/comments"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userToken, forHTTPHeaderField: "X-User-Token")
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        if httpResponse.statusCode != 200 && httpResponse.statusCode != 201 {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw FeedbackClientError.unexpectedStatus(code: httpResponse.statusCode, message: message)
        }
        return try decoder.decode(FeatureRequestComment.self, from: data)
    }
}

// MARK: - Private helpers

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
