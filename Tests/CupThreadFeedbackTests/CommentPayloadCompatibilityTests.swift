import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Public comment payload compatibility (#508)
//
// The published OpenAPI `FeatureRequestComment` component is a stale artifact:
// it still documents a phantom `authorEmail` and omits the `appId`/`updatedAt`
// the public comment record actually carries. These tests pin the served
// payload shape and the tolerance for pre-correction responses.

@Suite("FeatureRequestComment payload compatibility")
struct CommentPayloadCompatibilityTests {
    @Test func featureRequestCommentDecodesRecordWithoutAppIdOrUpdatedAt() throws {
        // Pre-correction responses omit appId/updatedAt; the model tolerates both.
        let json = Data("""
        {
            "id": "c-1",
            "featureRequestId": "fr-1",
            "authorName": null,
            "body": "This is a comment",
            "createdAt": "2026-01-01T00:00:00.000Z"
        }
        """.utf8)

        let comment = try JSONDecoder().decode(FeatureRequestComment.self, from: json)
        #expect(comment.appId == nil)
        #expect(comment.authorName == nil)
        #expect(comment.updatedAt == nil)
    }

    @Test func featureRequestCommentInitCarriesAppIdAndUpdatedAt() {
        let comment = FeatureRequestComment(
            id: "c-1",
            featureRequestId: "fr-1",
            appId: "app-1",
            body: "body",
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-02T00:00:00.000Z"
        )
        #expect(comment.appId == "app-1")
        #expect(comment.updatedAt == "2026-01-02T00:00:00.000Z")
    }

    @Test func featureRequestCommentRoundTripsServedRecord() throws {
        let comment = FeatureRequestComment(
            id: "c-1",
            featureRequestId: "fr-1",
            appId: "app-1",
            authorName: "Lex",
            body: "body",
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-02T00:00:00.000Z"
        )

        let encoded = try JSONEncoder().encode(comment)
        let decoded = try JSONDecoder().decode(FeatureRequestComment.self, from: encoded)
        #expect(decoded == comment)
        #expect(decoded.appId == "app-1")
        #expect(decoded.updatedAt == "2026-01-02T00:00:00.000Z")
    }
}
