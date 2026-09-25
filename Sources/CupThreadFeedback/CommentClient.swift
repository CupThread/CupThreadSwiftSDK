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

    /// The comments endpoint's maximum page size (server limit is 200), so
    /// walking a full thread fetches the fewest possible pages.
    private static let commentsMaxPageSize = 200

    /// Fetches every visible comment on a feature request, oldest first.
    ///
    /// The endpoint pages results (at most 200 rows per response, default
    /// 200), so this walks every cursor page — collecting comments until the
    /// server reports no further page, the collected count reaches the
    /// page's ``ListCommentsResult/total``, or a page adds no new ids.
    /// ``ListCommentsResult/total`` is the visible thread size (hidden and
    /// deleted comments excluded), not a single page's length. Callers that
    /// want one page, or the authoritative `total`, can use
    /// ``fetchComments(featureRequestId:limit:cursor:)``.
    /// - Parameter featureRequestId: Id of the feature request.
    /// - Returns: The visible comments, oldest first.
    /// - Throws: ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
    ///   (including `400` for a malformed cursor) or
    ///   ``FeedbackClientError/invalidResponse``.
    public func fetchComments(featureRequestId: String) async throws -> [FeatureRequestComment] {
        var collected: [FeatureRequestComment] = []
        var seenIDs = Set<String>()
        var cursor: String?
        while true {
            let page = try await fetchComments(
                featureRequestId: featureRequestId,
                limit: Self.commentsMaxPageSize,
                cursor: cursor
            )
            let freshComments = page.comments.filter { seenIDs.insert($0.id).inserted }
            collected.append(contentsOf: freshComments)
            // `total` counts the whole visible thread. A page that yields
            // nothing new would replay forever; stop on the last page, once
            // the thread is complete, or on a misbehaving cursor.
            let reachedTotal = page.total > 0 && collected.count >= page.total
            guard page.hasMore, let nextCursor = page.nextCursor, !freshComments.isEmpty, !reachedTotal else {
                return collected
            }
            cursor = nextCursor
        }
    }

    /// Fetches one page of comments on a feature request, oldest first.
    ///
    /// The server orders comments by `(createdAt ASC, id ASC)` and pages
    /// them behind an opaque keyset cursor: pass a previous page's
    /// ``ListCommentsResult/nextCursor`` back as `cursor` to move forward.
    /// Malformed cursors are rejected server-side with `400 Bad Request`.
    /// ``ListCommentsResult/total`` is the visible thread size and stays
    /// independent of this page's row count.
    /// - Parameters:
    ///   - featureRequestId: Id of the feature request.
    ///   - limit: Comments per page. The server accepts 1...200 (default 200).
    ///   - cursor: Opaque keyset cursor from a previous page's
    ///     ``ListCommentsResult/nextCursor``; omit for the first page.
    /// - Returns: The page's comments plus `total` / `hasMore` / `nextCursor`.
    /// - Throws: ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
    ///   (including `400` for a malformed cursor) or
    ///   ``FeedbackClientError/invalidResponse``.
    public func fetchComments(
        featureRequestId: String,
        limit: Int,
        cursor: String? = nil
    ) async throws -> ListCommentsResult {
        let base = configuration.baseURL.appending(
            path: "/api/v1/feature-requests/\(featureRequestId)/comments"
        )
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: true) else {
            throw FeedbackClientError.invalidResponse
        }
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw FeedbackClientError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyCorrelationHeaders(userToken: nil, requestID: nextRequestID(), to: &request)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        try validateResponse(httpResponse, data: data, accepted: [200])
        return try decoder.decode(ListCommentsResult.self, from: data)
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
            parentId: draft.parentId?.nilIfEmpty,
            replyToAuthorName: draft.replyToAuthorName?.nilIfEmpty
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
