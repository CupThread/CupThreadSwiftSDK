import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Full-thread snapshot completeness

/// `CommentsView` needs to know whether a full-thread walk reached the end of
/// the thread before treating an absent locally posted comment as moderated.
/// These tests pin that the capped walk and the completed walk are
/// distinguishable (issue #545).
@Suite("CommentThreadSnapshot", .serialized)
struct CommentThreadSnapshotTests {
    private static let apiHost = "comment-thread-snapshot.example.com"

    private static func makeSnapshotClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    @Test func completeWalkReportsTheEndOfTheThread() async throws {
        var requestCount = 0
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            requestCount += 1
            if requestCount == 1 {
                return snapshotCommentPage(
                    comments: [snapshotCommentJSON(id: "c-1")],
                    total: 2,
                    hasMore: true,
                    nextCursor: "cur-1"
                )
            }
            return snapshotCommentPage(
                comments: [snapshotCommentJSON(id: "c-2")],
                total: 2,
                hasMore: false,
                nextCursor: nil
            )
        }

        let snapshot = try await Self.makeSnapshotClient().fetchCommentThread(featureRequestId: "fr-1")

        #expect(snapshot.comments.map(\.id) == ["c-1", "c-2"])
        #expect(snapshot.isComplete, "A walk that reaches the last page is authoritative")
    }

    @Test func pageCappedWalkReportsAnIncompleteThread() async throws {
        var requestCount = 0
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            requestCount += 1
            return snapshotCommentPage(
                comments: [snapshotCommentJSON(id: "c-\(requestCount)")],
                total: 0,
                hasMore: true,
                nextCursor: "cur-\(requestCount)"
            )
        }

        let snapshot = try await Self.makeSnapshotClient().fetchCommentThread(
            featureRequestId: "fr-1",
            maxPages: 3
        )

        #expect(snapshot.comments.count == 3)
        #expect(!snapshot.isComplete, "A capped walk cannot prove that an absent row does not exist")
    }
}

// MARK: - Fixtures

private func snapshotCommentJSON(id: String) -> [String: Any] {
    [
        "id": id,
        "featureRequestId": "fr-1",
        "body": "Comment \(id)",
        "createdAt": "2026-01-01T00:00:00.000Z"
    ]
}

private func snapshotCommentPage(
    comments: [[String: Any]],
    total: Int,
    hasMore: Bool,
    nextCursor: String?
) -> (HTTPURLResponse, Data) {
    var payload: [String: Any] = [
        "comments": comments,
        "total": total,
        "hasMore": hasMore
    ]
    payload["nextCursor"] = nextCursor ?? NSNull()
    return (makeHTTPResponse(), (try? encodeJSON(payload)) ?? Data())
}
