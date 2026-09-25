import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Models

@Suite("CommentModels")
struct CommentModelsTests {
    @Test func featureRequestCommentDecodesWithAllFields() throws {
        let json = Data("""
        {
            "id": "c-1",
            "featureRequestId": "fr-1",
            "authorName": "Lex",
            "authorEmail": "lex@example.com",
            "authorAvatarUrl": "https://example.com/avatar.png",
            "authorClerkId": "clerk_lex",
            "body": "This is a comment",
            "parentId": "c-0",
            "replyToClerkId": "user_123",
            "replyToAuthorName": "Bob",
            "isHidden": true,
            "createdAt": "2026-01-01T00:00:00.000Z"
        }
        """.utf8)

        let comment = try JSONDecoder().decode(FeatureRequestComment.self, from: json)
        #expect(comment.id == "c-1")
        #expect(comment.featureRequestId == "fr-1")
        #expect(comment.authorName == "Lex")
        #expect(comment.authorEmail == "lex@example.com")
        #expect(comment.authorAvatarUrl == "https://example.com/avatar.png")
        #expect(comment.authorClerkId == "clerk_lex")
        #expect(comment.body == "This is a comment")
        #expect(comment.parentId == "c-0")
        #expect(comment.replyToClerkId == "user_123")
        #expect(comment.replyToAuthorName == "Bob")
        #expect(comment.isHidden == true)
        #expect(comment.createdAt == "2026-01-01T00:00:00.000Z")
    }

    @Test func featureRequestCommentDecodesWithRequiredFieldsOnly() throws {
        let json = Data("""
        {
            "id": "c-1",
            "featureRequestId": "fr-1",
            "body": "This is a comment",
            "createdAt": "2026-01-01T00:00:00.000Z"
        }
        """.utf8)

        let comment = try JSONDecoder().decode(FeatureRequestComment.self, from: json)
        #expect(comment.id == "c-1")
        #expect(comment.featureRequestId == "fr-1")
        #expect(comment.authorName == nil)
        #expect(comment.authorEmail == nil)
        #expect(comment.authorAvatarUrl == nil)
        #expect(comment.authorClerkId == nil)
        #expect(comment.body == "This is a comment")
        #expect(comment.parentId == nil)
        #expect(comment.replyToClerkId == nil)
        #expect(comment.replyToAuthorName == nil)
        #expect(comment.isHidden == nil)
        #expect(comment.createdAt == "2026-01-01T00:00:00.000Z")
    }

    @Test func commentDraftDefaultValues() {
        let draft = CommentDraft()
        #expect(draft.body.isEmpty)
        #expect(draft.authorName.isEmpty)
        #expect(draft.authorEmail.isEmpty)
        #expect(draft.authorAvatarUrl.isEmpty)
        #expect(draft.parentId == nil)
        #expect(draft.replyToClerkId == nil)
        #expect(draft.replyToAuthorName == nil)
    }

    @Test func featureRequestCommentCreatedAtDateParsing() throws {
        let plain = FeatureRequestComment(
            id: "1", featureRequestId: "1", authorName: nil, authorEmail: nil,
            authorAvatarUrl: nil, body: "x", parentId: nil, replyToClerkId: nil,
            replyToAuthorName: nil, isHidden: nil, createdAt: "2026-01-01T00:00:00Z"
        )
        #expect(plain.createdAtDate != nil)

        let fractional = FeatureRequestComment(
            id: "1", featureRequestId: "1", authorName: nil, authorEmail: nil,
            authorAvatarUrl: nil, body: "x", parentId: nil, replyToClerkId: nil,
            replyToAuthorName: nil, isHidden: nil, createdAt: "2026-01-01T00:00:00.123Z"
        )
        #expect(fractional.createdAtDate != nil)

        let invalid = FeatureRequestComment(
            id: "1", featureRequestId: "1", authorName: nil, authorEmail: nil,
            authorAvatarUrl: nil, body: "x", parentId: nil, replyToClerkId: nil,
            replyToAuthorName: nil, isHidden: nil, createdAt: "not-a-date"
        )
        #expect(invalid.createdAtDate == nil)
    }

    @Test func moderatedCommentRedactsContentAndDisablesActions() {
        let hiddenComment = FeatureRequestComment(
            id: "c-hidden",
            featureRequestId: "fr-1",
            authorName: "OffensiveUser",
            authorEmail: "bad@example.com",
            authorAvatarUrl: "https://example.com/avatar.png",
            authorClerkId: "clerk_bad",
            body: "Sensitive or abusive content that must not be shown",
            parentId: "c-0",
            replyToClerkId: "clerk_parent",
            replyToAuthorName: "Alice",
            isHidden: true,
            createdAt: "2026-01-01T00:00:00.000Z"
        )

        #expect(hiddenComment.isModerated == true)
        let display = hiddenComment.displayModel
        #expect(display.isModerated == true)
        #expect(display.displayBody != hiddenComment.body)
        #expect(display.displayBody == CupThreadStrings.tr("cupthread.comments.removed_by_moderator"))
        #expect(display.authorName == nil)
        #expect(display.authorAvatarUrl == nil)
        #expect(display.authorClerkId == nil)
        #expect(display.canReply == false)
        #expect(display.canOpenAuthorProfile == false)
        #expect(display.replyToAuthorName == "Alice")
        #expect(display.replyToClerkId == nil)
    }

    @Test func visibleCommentPreservesContentAndAllowsActions() {
        let visibleComment = FeatureRequestComment(
            id: "c-visible",
            featureRequestId: "fr-1",
            authorName: "Alice",
            authorEmail: "alice@example.com",
            authorAvatarUrl: "https://example.com/avatar.png",
            authorClerkId: "clerk_alice",
            body: "Helpful feedback",
            parentId: "c-0",
            replyToClerkId: "clerk_bob",
            replyToAuthorName: "Bob",
            isHidden: false,
            createdAt: "2026-01-01T00:00:00.000Z"
        )

        #expect(visibleComment.isModerated == false)
        let display = visibleComment.displayModel
        #expect(display.isModerated == false)
        #expect(display.displayBody == "Helpful feedback")
        #expect(display.authorName == "Alice")
        #expect(display.authorAvatarUrl == "https://example.com/avatar.png")
        #expect(display.authorClerkId == "clerk_alice")
        #expect(display.canReply == true)
        #expect(display.canOpenAuthorProfile == true)
        #expect(display.replyToAuthorName == "Bob")
        #expect(display.replyToClerkId == "clerk_bob")
    }

    @Test func unmoderatedCommentWithNilHiddenTreatsAsVisible() {
        let comment = FeatureRequestComment(
            id: "c-nil",
            featureRequestId: "fr-1",
            authorName: nil,
            body: "Anonymous comment",
            isHidden: nil,
            createdAt: "2026-01-01T00:00:00.000Z"
        )

        #expect(comment.isModerated == false)
        let display = comment.displayModel
        #expect(display.isModerated == false)
        #expect(display.displayBody == "Anonymous comment")
        #expect(display.authorName == CupThreadStrings.tr("cupthread.features.anonymous"))
        #expect(display.canReply == true)
        #expect(display.canOpenAuthorProfile == false)
    }
}

// MARK: - Client

@Suite("CommentClient", .serialized)
struct CommentClientTests {
    static let apiHost = "comments.example.com"

    static func makeAPIClient(
        authenticationProvider: (@Sendable () async -> String?)? = nil
    ) -> FeedbackClient {
        makeClient(
            baseURL: URL(string: "https://\(apiHost)")!,
            authenticationProvider: authenticationProvider
        )
    }

    /// The created-comment success envelope the server answers with (`201`).
    static func createdCommentEnvelope(
        overrides: [String: Any] = [:]
    ) throws -> Data {
        var comment: [String: Any] = [
            "id": "c-new",
            "featureRequestId": "fr-123",
            "body": "New comment body",
            "authorClerkId": "u_0123abcd",
            "authorName": NSNull(),
            "createdAt": "2026-01-01T00:00:00.000Z"
        ]
        for (key, value) in overrides {
            comment[key] = value
        }
        return try encodeJSON(["comment": comment])
    }

    @Test func fetchCommentsHitsCorrectEndpoint() async throws {
        let capture = CaptureBox<URL>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request.url
            return (makeHTTPResponse(), try encodeJSON(["comments": []]))
        }

        _ = try await Self.makeAPIClient().fetchComments(featureRequestId: "fr-123")

        let url = try #require(capture.value)
        #expect(url.path == "/api/v1/feature-requests/fr-123/comments")
        // The full-thread read always asks for the server's max page (200)
        // and only sends `cursor` on follow-up pages.
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )
        #expect(query["limit"] == "200")
        #expect(query["cursor"] == nil)
    }

    @Test func fetchCommentsDecodesResponse() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            let body: [String: Any] = [
                "comments": [
                    [
                        "id": "c-1",
                        "featureRequestId": "fr-1",
                        "body": "Test comment",
                        "createdAt": "2026-01-01T00:00:00.000Z"
                    ]
                ]
            ]
            return (makeHTTPResponse(), try encodeJSON(body))
        }

        let comments = try await Self.makeAPIClient().fetchComments(featureRequestId: "fr-1")
        #expect(comments.count == 1)
        #expect(comments[0].id == "c-1")
    }

    @Test func postCommentSendsCanonicalPayloadAndDecodesEnvelope() async throws {
        // Issue #5: the canonical create-comment contract — the request body
        // carries exactly `body`, `parentId`, and `replyToAuthorName` (nil
        // optionals omitted, author fields never sent), and the `201`
        // response is the `{"comment": …}` envelope.
        let capture = CaptureBox<URLRequest>()
        let bodyCapture = CaptureBox<Data>()

        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            bodyCapture.value = bodyData(from: request)
            return (makeHTTPResponse(status: 201), try Self.createdCommentEnvelope())
        }

        let draft = CommentDraft(body: "  New comment body  ", authorName: "Lex", parentId: "c-0")
        let created = try await Self.makeAPIClient().postComment(
            featureRequestId: "fr-123",
            draft: draft,
            userToken: "token-123"
        )

        let req = try #require(capture.value)
        #expect(req.url?.path == "/api/v1/feature-requests/fr-123/comments")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let rawData = try #require(bodyCapture.value)
        let json = try #require(parseJSONDict(rawData))
        #expect(json["body"] as? String == "New comment body")
        #expect(json["parentId"] as? String == "c-0")
        #expect(json.keys.contains("authorName") == false)
        #expect(json.keys.contains("authorEmail") == false)
        #expect(json.keys.contains("authorAvatarUrl") == false)
        #expect(json.keys.contains("replyToClerkId") == false)
        #expect(json.values.contains { $0 is NSNull } == false)

        #expect(created.id == "c-new")
        #expect(created.authorClerkId == "u_0123abcd")
    }

    @Test func postCommentPayloadOmitsUnsetReplyTargetEntirely() async throws {
        let bodyCapture = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            bodyCapture.value = bodyData(from: request)
            return (makeHTTPResponse(status: 201), try Self.createdCommentEnvelope())
        }

        _ = try await Self.makeAPIClient().postComment(
            featureRequestId: "fr-1",
            draft: CommentDraft(body: "Top-level comment"),
            userToken: "token-123"
        )

        let rawData = try #require(bodyCapture.value)
        let json = try #require(parseJSONDict(rawData))
        // Optional fields must be omitted, never encoded as null — the
        // server's schema rejects explicit nulls with 400 before auth.
        #expect(json.count == 1)
        #expect(json["body"] as? String == "Top-level comment")
    }

    @Test func postCommentOmitsEmptyOrWhitespaceParentIdAndReplyToAuthorName() async throws {
        let bodyCapture = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            bodyCapture.value = bodyData(from: request)
            return (makeHTTPResponse(status: 201), try Self.createdCommentEnvelope())
        }

        let draft = CommentDraft(
            body: "Top-level comment with empty fields",
            parentId: "   ",
            replyToAuthorName: ""
        )

        _ = try await Self.makeAPIClient().postComment(
            featureRequestId: "fr-1",
            draft: draft,
            userToken: "token-123"
        )

        let rawData = try #require(bodyCapture.value)
        let json = try #require(parseJSONDict(rawData))
        #expect(json.count == 1)
        #expect(json["body"] as? String == "Top-level comment with empty fields")
        #expect(json["parentId"] == nil)
        #expect(json["replyToAuthorName"] == nil)
    }

    @Test func postCommentTrimsSurroundingWhitespaceFromParentIdAndReplyToAuthorName() async throws {
        let bodyCapture = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            bodyCapture.value = bodyData(from: request)
            return (makeHTTPResponse(status: 201), try Self.createdCommentEnvelope())
        }

        let draft = CommentDraft(
            body: "Reply with whitespace around fields",
            parentId: "  c-parent-123  ",
            replyToAuthorName: "  Bob  "
        )

        _ = try await Self.makeAPIClient().postComment(
            featureRequestId: "fr-1",
            draft: draft,
            userToken: "token-123"
        )

        let rawData = try #require(bodyCapture.value)
        let json = try #require(parseJSONDict(rawData))
        #expect(json["parentId"] as? String == "c-parent-123")
        #expect(json["replyToAuthorName"] as? String == "Bob")
    }

    @Test func postCommentSetsUserTokenHeader() async throws {
        let capture = CaptureBox<String?>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request.value(forHTTPHeaderField: "X-User-Token")
            return (makeHTTPResponse(status: 201), try Self.createdCommentEnvelope())
        }

        let token = "my-user-token"
        _ = try await Self.makeAPIClient().postComment(
            featureRequestId: "fr-123",
            draft: CommentDraft(body: "Test"),
            userToken: token
        )

        #expect(capture.value == token)
    }

    @Test func postCommentSendsBearerTokenFromAuthenticationProvider() async throws {
        let capture = CaptureBox<String?>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request.value(forHTTPHeaderField: "Authorization")
            return (makeHTTPResponse(status: 201), try Self.createdCommentEnvelope())
        }

        let client = Self.makeAPIClient(authenticationProvider: { "clerk-jwt-token" })
        #expect(client.supportsAuthentication)
        _ = try await client.postComment(
            featureRequestId: "fr-123",
            draft: CommentDraft(body: "Test"),
            userToken: "token-123"
        )

        #expect(capture.value == "Bearer clerk-jwt-token")
    }

    @Test func postCommentWithProviderReturningNilOmitsAuthorizationHeader() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(status: 201), try Self.createdCommentEnvelope())
        }

        let client = Self.makeAPIClient(authenticationProvider: { nil })
        _ = try await client.postComment(
            featureRequestId: "fr-123",
            draft: CommentDraft(body: "Test"),
            userToken: "token-123"
        )

        let req = try #require(capture.value)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(req.value(forHTTPHeaderField: "X-User-Token") == "token-123")
    }

    @Test func postCommentWithoutProviderOmitsAuthorizationHeader() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(status: 201), try Self.createdCommentEnvelope())
        }

        let client = Self.makeAPIClient()
        #expect(client.supportsAuthentication == false)
        _ = try await client.postComment(
            featureRequestId: "fr-123",
            draft: CommentDraft(body: "Test"),
            userToken: "token-123"
        )

        let req = try #require(capture.value)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func postCommentMapsAuthenticationRequiredEnvelopeToTypedError() async throws {
        // Anonymous comment creation: the server answers 401 with the
        // documented `authentication_required` code (issue #5).
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 401),
                try encodeJSON([
                    "error": "Sign in is required to comment",
                    "code": "authentication_required"
                ])
            )
        }

        do {
            _ = try await Self.makeAPIClient().postComment(
                featureRequestId: "fr-123",
                draft: CommentDraft(body: "Test"),
                userToken: "token-123"
            )
            Issue.record("Expected authenticationRequired")
        } catch let error as FeedbackClientError {
            #expect(error == .authenticationRequired)
        }
    }

    @Test func other401sStayUnexpectedStatus() async throws {
        // Only the documented `authentication_required` envelope maps to the
        // typed error; any other 401 keeps the diagnostic unexpectedStatus.
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 401), try encodeJSON(["error": "Invalid token"]))
        }

        do {
            _ = try await Self.makeAPIClient().fetchComments(featureRequestId: "fr-123")
            Issue.record("Expected unexpectedStatus")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, _) = error else {
                Issue.record("Expected unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 401)
        }
    }
}
