import Foundation
import os

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

/// One walk of a feature request's visible comment thread.
///
/// ``isComplete`` distinguishes a walk that reached the end of the thread
/// from one the page cap stopped early: an absent locally posted comment is
/// only authoritative evidence of moderation/deletion when the walk saw the
/// whole thread.
struct CommentThreadSnapshot: Equatable, Sendable {
    /// Visible comments in server order (oldest first).
    let comments: [FeatureRequestComment]
    /// Whether the walk observed the end of the thread.
    let isComplete: Bool
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
    ///
    /// The walk stops safely upon reaching `maxPages` (defaults to
    /// ``FeedbackClient/defaultMaxPages``, 100) to guarantee termination against
    /// runaway backends, proxy loops, or shifting keyset cursors. When the cap is
    /// reached, comments collected so far are returned and a warning diagnostic is logged.
    /// - Parameters:
    ///   - featureRequestId: Id of the feature request.
    ///   - maxPages: Maximum number of cursor pages to fetch before stopping;
    ///     defaults to ``FeedbackClient/defaultMaxPages`` (100).
    /// - Returns: The visible comments, oldest first.
    /// - Throws: ``FeedbackClientError/authenticationRequired`` when anonymous
    ///   access is disabled for the app (HTTP 401),
    ///   ``FeedbackClientError/forbidden(message:requestId:)`` when the
    ///   server's permission policy rejects the read (HTTP 403),
    ///   ``FeedbackClientError/commentsUnavailable(message:requestId:)`` when
    ///   comments are not available or disabled (HTTP 404),
    ///   ``FeedbackClientError/rateLimited`` when the shared per-client read
    ///   budget is exhausted (HTTP 429 — retryable after a short back-off),
    ///   ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
    ///   (including `400` for a malformed cursor),
    ///   ``FeedbackClientError/invalidResponse``, or `CancellationError`
    ///   when the enclosing task is cancelled.
    public func fetchComments(
        featureRequestId: String,
        maxPages: Int = Self.defaultMaxPages
    ) async throws -> [FeatureRequestComment] {
        try await fetchCommentThread(
            featureRequestId: featureRequestId,
            maxPages: maxPages
        ).comments
    }

    /// Fetches every visible comment on a feature request and reports whether
    /// the walk reached the end of the thread.
    ///
    /// ``CommentsView`` uses this variant to decide whether a locally posted
    /// comment missing from the fetched page is genuinely gone from the
    /// server. A capped walk can omit rows that exist beyond the last page,
    /// so its absences are not evidence of moderation.
    func fetchCommentThread(
        featureRequestId: String,
        maxPages: Int = Self.defaultMaxPages
    ) async throws -> CommentThreadSnapshot {
        let effectiveMaxPages = max(1, maxPages)
        var collected: [FeatureRequestComment] = []
        var seenIDs = Set<String>()
        var cursor: String?
        var pagesFetched = 0
        while pagesFetched < effectiveMaxPages {
            try Task.checkCancellation()
            pagesFetched += 1
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
                return CommentThreadSnapshot(
                    comments: collected,
                    isComplete: !page.hasMore || reachedTotal
                )
            }
            cursor = nextCursor
        }
        paginationLogger.warning(
            "Comments pagination reached maximum page cap (\(effectiveMaxPages, privacy: .public)) for app '\(self.configuration.appKey, privacy: .public)' on request '\(featureRequestId, privacy: .public)'; returning \(collected.count, privacy: .public) collected comments."
        )
        return CommentThreadSnapshot(comments: collected, isComplete: false)
    }

    /// Fetches one page of comments on a feature request, oldest first.
    ///
    /// The server orders comments by `(createdAt ASC, id ASC)` and pages
    /// them behind an opaque keyset cursor: pass a previous page's
    /// ``ListCommentsResult/nextCursor`` back as `cursor` to move forward.
    /// Malformed cursors are rejected server-side with `400 Bad Request`.
    /// ``ListCommentsResult/total`` is the visible thread size and stays
    /// independent of this page's row count. When the client is created with an
    /// authentication provider, the signed-in user's bearer token is attached as
    /// `Authorization: Bearer …` so comments load when `allowAnonymousRoadmap = false`.
    /// - Parameters:
    ///   - featureRequestId: Id of the feature request.
    ///   - limit: Comments per page. The server accepts 1...200 (default 200);
    ///     values outside that range are clamped to it.
    ///   - cursor: Opaque keyset cursor from a previous page's
    ///     ``ListCommentsResult/nextCursor``; omit for the first page.
    ///     Blank or whitespace-only values are dropped.
    /// - Returns: The page's comments plus `total` / `hasMore` / `nextCursor`.
    /// - Throws: ``FeedbackClientError/authenticationRequired`` when anonymous
    ///   access is disabled for the app (HTTP 401),
    ///   ``FeedbackClientError/forbidden(message:requestId:)`` when the
    ///   server's permission policy rejects the read (HTTP 403),
    ///   ``FeedbackClientError/commentsUnavailable(message:requestId:)`` when
    ///   the server answers HTTP 404 with the documented JSON error envelope
    ///   (comments are not available or disabled on this request),
    ///   ``FeedbackClientError/rateLimited`` when the shared per-client read
    ///   budget is exhausted (HTTP 429 — retryable after a short back-off),
    ///   ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
    ///   (including `400` for a malformed cursor, and a 404 that arrives
    ///   *without* the JSON envelope — a router fallback, deploy skew, or a
    ///   wrong `baseURL`), or
    ///   ``FeedbackClientError/invalidResponse`` when `featureRequestId`
    ///   cannot be a valid feature-request id (empty, whitespace-padded to
    ///   nothing, or containing path/query/percent characters — deep-link ids
    ///   are untrusted input; rejected locally with no request sent).
    public func fetchComments(
        featureRequestId: String,
        limit: Int,
        cursor: String? = nil
    ) async throws -> ListCommentsResult {
        let trimmedID = featureRequestId.trimmingCharacters(in: .whitespacesAndNewlines)
        // Deep-link, push, and share-link ids are untrusted input (BUG-31):
        // an id that cannot be a single opaque path segment can never name a
        // real request, so reject it locally instead of interpolating path
        // separators, `..`, or query/fragment characters into the URL while
        // `Authorization: Bearer` and `X-User-Token` headers are attached.
        guard FeatureRequestIDGrammar.isValid(trimmedID) else {
            throw FeedbackClientError.invalidResponse
        }
        let base = configuration.baseURL.appending(
            path: "/api/v1/feature-requests/\(trimmedID)/comments"
        )
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: true) else {
            throw FeedbackClientError.invalidResponse
        }
        // The gateway rejects page sizes outside 1...200 with 400, so clamp
        // here instead of letting invalid values reach it (#425).
        let effectiveLimit = min(max(1, limit), Self.commentsMaxPageSize)
        var queryItems = [URLQueryItem(name: "limit", value: String(effectiveLimit))]
        if let cursor = cursor?.nilIfEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.setQueryItemsEncodingPlus(queryItems)
        guard let url = components.url else {
            throw FeedbackClientError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        try applyCorrelationHeaders(userToken: nil, requestID: nextRequestID(), to: &request)
        await applyBearerToken(to: &request)

        let (data, response) = try await session.data(for: request, delegate: SameOriginRedirectLimiter())
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        if httpResponse.statusCode == 404,
           let envelope = try? decoder.decode(APIErrorEnvelope.self, from: data),
           let message = envelope.error?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            // Only the API's documented resource-404 envelope means "comments
            // are unavailable on this request" (BUG-31). A bare router
            // fallback (text/plain "404 Not Found", empty body — what
            // production answers on deploy skew or a wrong `baseURL`) falls
            // through to `validateResponse` and surfaces as
            // `.unexpectedStatus`, so an infrastructure misconfiguration is
            // not misreported as a per-request comments-disabled state.
            throw FeedbackClientError.commentsUnavailable(message: message, requestId: httpResponse.cupthreadRequestID)
        }
        // The route's 401/403 mean anonymous access is disabled or the
        // server's permission policy rejected the read; map them to the typed
        // permission errors like the sibling endpoints (#358).
        try validateResponse(httpResponse, data: data, accepted: [200], mapsPermissionErrors: true)
        return try decodeSuccess(ListCommentsResult.self, from: data)
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
    ///   caller is not signed in (HTTP 401 — this sign-in gate fires before
    ///   the lookup, but only after the local checks below succeed, so an
    ///   anonymous caller receives it for any request that survives local
    ///   `featureRequestId` and draft validation; an id failing that
    ///   validation throws ``FeedbackClientError/invalidResponse`` locally
    ///   with no network round trip and never reaches the gate),
    ///   ``FeedbackClientError/forbidden(message:requestId:)`` — no current
    ///   server state answers it on this operation; the generic permission
    ///   mapping is kept for deploy skew (pre-convention servers answered an
    ///   undocumented 403 for an unapproved request, which the uniform-404
    ///   convention of SaaS#1171 now hides the same as a missing one),
    ///   ``FeedbackClientError/commentsUnavailable(message:requestId:)`` when
    ///   the documented JSON envelope reports the feature request is missing,
    ///   unapproved, or its comments are disabled (HTTP 404 with a non-empty
    ///   `error` — since SaaS#1171 an unapproved request answers the same
    ///   uniform 404 body as a missing one),
    ///   ``FeedbackClientError/invalidParent(message:requestId:)`` when the
    ///   reply target is missing, hidden, or not on this feature request
    ///   (HTTP 400 `invalid_parent`),
    ///   ``FeedbackClientError/textTooLong`` when the encoded payload exceeds
    ///   the client-side intake byte budget (BUG-18) — rejected locally with
    ///   no network round trip; shorten the comment and post again,
    ///   ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
    ///   or ``FeedbackClientError/invalidResponse`` otherwise — the latter is
    ///   also thrown locally, before any request is built, when
    ///   `featureRequestId` cannot be a valid feature-request id (empty,
    ///   whitespace-padded to nothing, or containing path/query/percent
    ///   characters) or `draft.body` is empty after trimming.
    public func postComment(
        featureRequestId: String,
        draft: CommentDraft,
        userToken: String
    ) async throws -> FeatureRequestComment {
        // Reject a blank, whitespace-only, or newline-bearing userToken
        // locally so the correlation header is never silently omitted (#497).
        let identityToken = try validatedUserToken(userToken)
        let trimmedID = featureRequestId.trimmingCharacters(in: .whitespacesAndNewlines)
        // Same untrusted-input grammar as `fetchComments` (BUG-31): never
        // build a URL path from an id that cannot be a single opaque segment.
        guard FeatureRequestIDGrammar.isValid(trimmedID) else {
            throw FeedbackClientError.invalidResponse
        }
        // A body that is empty after trimming can only be rejected by the
        // server (`400 Validation failed`); fail fast locally so headless
        // callers do not spend a network round trip — or the signed-in
        // session's bearer token — on a request that cannot succeed.
        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw FeedbackClientError.invalidResponse
        }
        let payload = CommentSubmitPayload(
            body: body,
            parentId: draft.parentId?.nilIfEmpty,
            replyToAuthorName: draft.replyToAuthorName?.nilIfEmpty
        )

        var request = URLRequest(url: configuration.baseURL.appending(path: "/api/v1/feature-requests/\(trimmedID)/comments"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try applyCorrelationHeaders(userToken: identityToken, requestID: nextRequestID(), to: &request)
        await applyBearerToken(to: &request)
        request.httpBody = try encodedIntakeBody(payload)

        let (data, response) = try await session.data(for: request, delegate: SameOriginRedirectLimiter())
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        // The route's 401/403 mean the caller is not signed in or the
        // server's permission policy rejected the comment; map them to the
        // typed permission errors like the sibling endpoints (#358).
        // Only the API's documented resource-404 envelope means "comments are
        // unavailable" (BUG-31, #530). A bare router fallback (text/plain,
        // empty body, or JSON without an `error` string — what production
        // answers on deploy skew or a wrong `baseURL`) falls through to
        // `.unexpectedStatus`, so infrastructure misconfiguration is not
        // misreported as a per-request comments-disabled state.
        try validateResponse(
            httpResponse,
            data: data,
            accepted: [200, 201],
            mapsPermissionErrors: true,
            mapResourceNotFound: { message, requestId in
                .commentsUnavailable(message: message, requestId: requestId)
            }
        )
        return try decodeSuccess(CreatedCommentResponse.self, from: data).comment
    }
}
