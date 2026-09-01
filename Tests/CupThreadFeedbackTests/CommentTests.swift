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
}

// MARK: - Client

@Suite("CommentClient", .serialized)
struct CommentClientTests {
    static let apiHost = "comments.example.com"

    static func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
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

    @Test func postCommentSendsPostWithCorrectBodyAndHeaders() async throws {
        let capture = CaptureBox<URLRequest>()
        let bodyCapture = CaptureBox<Data>()

        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            bodyCapture.value = bodyData(from: request)

            let responseBody: [String: Any] = [
                "id": "c-new",
                "featureRequestId": "fr-123",
                "body": "New comment body",
                "createdAt": "2026-01-01T00:00:00.000Z"
            ]
            return (makeHTTPResponse(status: 201), try encodeJSON(responseBody))
        }

        let draft = CommentDraft(body: " New comment body ", authorName: "Lex", parentId: "c-0")
        _ = try await Self.makeAPIClient().postComment(featureRequestId: "fr-123", draft: draft, userToken: "token-123")

        let req = try #require(capture.value)
        #expect(req.url?.path == "/api/v1/feature-requests/fr-123/comments")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let rawData = try #require(bodyCapture.value)
        let json = try #require(parseJSONDict(rawData))
        #expect(json["body"] as? String == "New comment body")
        #expect(json["authorName"] as? String == "Lex")
        #expect(json["parentId"] as? String == "c-0")
    }

    @Test func postCommentSetsUserTokenHeader() async throws {
        let capture = CaptureBox<String?>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request.value(forHTTPHeaderField: "X-User-Token")

            let responseBody: [String: Any] = [
                "id": "c-new",
                "featureRequestId": "fr-123",
                "body": "Test",
                "createdAt": "2026-01-01T00:00:00.000Z"
            ]
            return (makeHTTPResponse(status: 201), try encodeJSON(responseBody))
        }

        let token = "my-user-token"
        _ = try await Self.makeAPIClient().postComment(featureRequestId: "fr-123", draft: CommentDraft(body: "Test"), userToken: token)

        #expect(capture.value == token)
    }
}
