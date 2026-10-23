import Foundation
import SwiftUI
import Testing
@testable import CupThreadFeedback

// Issue #530 (BUG-31 follow-up): a failed submit must not consume the load
// path's thread-wide "comments unavailable" verdict. Setting that flag from
// `submitComment()` removes `composerForm` — and the `ErrorBanner` nested
// inside it — so the comment was silently lost with no explanation and no
// send control to retry. Only the load path owns the verdict; a submit
// failure stays in the banner and the composer remains mounted with the
// user's draft.
//
// SwiftUI `@State` writes are not observable on a unit-constructed view, so
// the state mutations are pinned with the source-scan pattern the sibling
// view tests use, and the retry contract is exercised end to end.
@Suite("CommentsView submit failure keeps the composer")
struct CommentsViewSubmitFailureTests {
    // MARK: - Source pin: the submit catch never sets the load-path verdict

    @Test func submitCatchDoesNotSetTheUnavailableVerdict() throws {
        let content = try String(
            contentsOf: try #require(Self.commentsViewSourceURL()),
            encoding: .utf8
        )

        let submitBody = try Self.functionBody(named: "func submitComment() async", in: content)
        #expect(
            !submitBody.contains("isCommentsUnavailable"),
            "submitComment() must never write isCommentsUnavailable: the flag removes the composer and its error banner (#530)"
        )
        #expect(
            submitBody.contains("submitError = FriendlyError.message(for: error)"),
            "the submit failure must still surface through the composer's error banner (#530)"
        )
    }

    @Test func onlyTheLoadPathSetsTheUnavailableVerdict() throws {
        let content = try String(
            contentsOf: try #require(Self.commentsViewSourceURL()),
            encoding: .utf8
        )

        let writes = content.components(separatedBy: "isCommentsUnavailable = true").count - 1
        #expect(
            writes == 1,
            "expected exactly one isCommentsUnavailable write (the load path), found \(writes)"
        )

        let loadBody = try Self.functionBody(named: "func loadComments() async", in: content)
        #expect(
            loadBody.contains("isCommentsUnavailable = true"),
            "the load path must still record the unavailable verdict for the full-thread error state"
        )
    }

    // MARK: - End to end: a failed submit preserves the draft for retry

    @Test @MainActor func failedSubmitKeepsTheDraftAndAllowsARetry() async throws {
        let host = "comments-bug31-retry.test.example.com"
        let capture = CaptureBox<[URLRequest]>()
        MockURLProtocol.setHandler(forHost: host) { request in
            capture.value = (capture.value ?? []) + [request]
            return (
                makeHTTPResponse(status: 404, headers: ["X-Request-Id": "req-bug31-first"]),
                try encodeJSON([
                    "error": "Comments are disabled for this feature request",
                    "code": "comments_disabled"
                ])
            )
        }
        defer { MockURLProtocol.setHandler(forHost: host, nil) }

        let view = CommentsView(
            client: makeClient(baseURL: URL(string: "https://\(host)")!),
            userToken: "token_123",
            featureRequestId: "fr_bug31",
            featureRequestTitle: "Title",
            preResolvedAuthentication: true,
            initialDraft: CommentDraft(body: "Please keep my draft")
        )

        await view.submitComment()

        // The failed attempt never clears the draft and the composer stays
        // available; a second attempt therefore still carries the same body.
        MockURLProtocol.setHandler(forHost: host) { request in
            capture.value = (capture.value ?? []) + [request]
            return (makeHTTPResponse(status: 201), try Self.createdCommentEnvelope())
        }

        await view.submitComment()

        let requests = try #require(capture.value)
        #expect(requests.count == 2, "the composer must remain usable after a failed submit (#530)")

        let first = try #require(bodyData(from: requests[0]))
        let firstPayload = try #require(parseJSONDict(first))
        #expect(firstPayload["body"] as? String == "Please keep my draft")

        let retry = try #require(bodyData(from: requests[1]))
        let retryPayload = try #require(parseJSONDict(retry))
        #expect(
            retryPayload["body"] as? String == "Please keep my draft",
            "a failed submit must not discard the draft, so the retry keeps the text (#530)"
        )
    }

    // MARK: - Fixtures

    /// The body of the first function whose declaration starts with `marker`.
    private static func functionBody(named marker: String, in content: String) throws -> Substring {
        let start = try #require(
            content.range(of: marker),
            "the \(marker) anchor was renamed; update this scan"
        )
        let remainder = content[start.upperBound...]
        // Brace matching keeps the scan inside the intended function even
        // when sibling functions also contain similar statements.
        var depth = 0
        var started = false
        var index = remainder.startIndex
        while index < remainder.endIndex {
            let character = remainder[index]
            if character == "{" {
                depth += 1
                started = true
            } else if character == "}" {
                depth -= 1
                if started && depth == 0 {
                    return remainder[..<index]
                }
            }
            index = remainder.index(after: index)
        }
        return remainder
    }

    /// The created-comment success envelope the server answers with (`201`).
    private static func createdCommentEnvelope() throws -> Data {
        try encodeJSON(["comment": [
            "id": "c-bug31",
            "featureRequestId": "fr_bug31",
            "body": "Please keep my draft",
            "authorName": NSNull(),
            "createdAt": "2026-01-01T00:00:00.000Z"
        ]])
    }

    private static func commentsViewSourceURL() -> URL? {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            directory.deleteLastPathComponent()
            let candidate = directory
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CupThreadFeedback", isDirectory: true)
                .appendingPathComponent("CommentsView.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
