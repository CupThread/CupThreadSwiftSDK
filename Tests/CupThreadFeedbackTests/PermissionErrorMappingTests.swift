import Foundation
import Testing
@testable import CupThreadFeedback

/// Verifies that `fetchComments`, `postComment`, `fetchChangelog`, and
/// `subscribeToChangelog` map permission rejections to the typed SDK errors
/// (API-20): a code-less HTTP 401 throws
/// ``FeedbackClientError/authenticationRequired`` and a plain HTTP 403 throws
/// ``FeedbackClientError/forbidden(message:requestId:)``, matching the
/// sibling endpoints covered by `PermissionErrorMappingTests` in
/// `PermissionGatingTests`. Envelope-qualified pairings
/// (`authentication_required`, `email_not_verified`, Turnstile) keep taking
/// precedence via `typedError` and are covered by `AnonymousAccessSyncTests`.
@Suite("Comment & changelog permission error mapping", .serialized)
struct CommentChangelogPermissionMappingTests {
    static let apiHost = "permission-mapping.example.com"

    static func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    @Test func fetchCommentsMapsCodeLess401ToAuthenticationRequired() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 401),
                try encodeJSON(["error": "Sign in required to view comments"])
            )
        }

        do {
            _ = try await Self.makeAPIClient().fetchComments(featureRequestId: "fr-123")
            Issue.record("Expected authenticationRequired")
        } catch let error as FeedbackClientError {
            #expect(error == .authenticationRequired)
        }
    }

    @Test func fetchCommentsMaps403ToForbidden() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 403, headers: ["X-Request-Id": "req-comments-403"]),
                try encodeJSON(["error": "Comments are disabled by policy"])
            )
        }

        do {
            _ = try await Self.makeAPIClient().fetchComments(featureRequestId: "fr-123")
            Issue.record("Expected forbidden")
        } catch let error as FeedbackClientError {
            guard case .forbidden(let message, let requestId) = error else {
                Issue.record("Expected forbidden, got \(error)")
                return
            }
            #expect(message == "Comments are disabled by policy")
            #expect(requestId == "req-comments-403")
            #expect(error.requestId == "req-comments-403")
        }
    }

    @Test func postCommentMapsCodeLess401ToAuthenticationRequired() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 401),
                try encodeJSON(["error": "Sign in required to comment"])
            )
        }

        do {
            _ = try await Self.makeAPIClient().postComment(
                featureRequestId: "fr-123",
                draft: CommentDraft(body: "Hello"),
                userToken: "tok-1"
            )
            Issue.record("Expected authenticationRequired")
        } catch let error as FeedbackClientError {
            #expect(error == .authenticationRequired)
        }
    }

    @Test func postCommentMaps403ToForbidden() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 403, headers: ["X-Request-Id": "req-post-403"]),
                try encodeJSON(["error": "Commenting is disabled by policy"])
            )
        }

        do {
            _ = try await Self.makeAPIClient().postComment(
                featureRequestId: "fr-123",
                draft: CommentDraft(body: "Hello"),
                userToken: "tok-1"
            )
            Issue.record("Expected forbidden")
        } catch let error as FeedbackClientError {
            guard case .forbidden(let message, let requestId) = error else {
                Issue.record("Expected forbidden, got \(error)")
                return
            }
            #expect(message == "Commenting is disabled by policy")
            #expect(requestId == "req-post-403")
            #expect(error.requestId == "req-post-403")
        }
    }

    @Test func fetchChangelogMapsCodeLess401ToAuthenticationRequired() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 401),
                try encodeJSON(["error": "Sign in required to view the changelog"])
            )
        }

        do {
            _ = try await Self.makeAPIClient().fetchChangelog()
            Issue.record("Expected authenticationRequired")
        } catch let error as FeedbackClientError {
            #expect(error == .authenticationRequired)
        }
    }

    @Test func fetchChangelogMaps403ToForbidden() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 403, headers: ["X-Request-Id": "req-changelog-403"]),
                try encodeJSON(["error": "Changelog is disabled by policy"])
            )
        }

        do {
            _ = try await Self.makeAPIClient().fetchChangelog()
            Issue.record("Expected forbidden")
        } catch let error as FeedbackClientError {
            guard case .forbidden(let message, let requestId) = error else {
                Issue.record("Expected forbidden, got \(error)")
                return
            }
            #expect(message == "Changelog is disabled by policy")
            #expect(requestId == "req-changelog-403")
            #expect(error.requestId == "req-changelog-403")
        }
    }

    @Test func subscribeToChangelogMapsCodeLess401ToAuthenticationRequired() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 401),
                try encodeJSON(["error": "Sign in required to subscribe"])
            )
        }

        do {
            _ = try await Self.makeAPIClient().subscribeToChangelog(
                email: "user@example.com",
                userToken: UUID().uuidString
            )
            Issue.record("Expected authenticationRequired")
        } catch let error as FeedbackClientError {
            #expect(error == .authenticationRequired)
        }
    }

    @Test func subscribeToChangelogMaps403ToForbidden() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 403, headers: ["X-Request-Id": "req-sub-403"]),
                try encodeJSON(["error": "Subscriptions are disabled by policy"])
            )
        }

        do {
            _ = try await Self.makeAPIClient().subscribeToChangelog(
                email: "user@example.com",
                userToken: UUID().uuidString
            )
            Issue.record("Expected forbidden")
        } catch let error as FeedbackClientError {
            guard case .forbidden(let message, let requestId) = error else {
                Issue.record("Expected forbidden, got \(error)")
                return
            }
            #expect(message == "Subscriptions are disabled by policy")
            #expect(requestId == "req-sub-403")
            #expect(error.requestId == "req-sub-403")
        }
    }

    @Test func subscribeToChangelogKeepsEmailNotVerifiedOnTypedPath() async throws {
        // The 403 `email_not_verified` pairing is envelope-qualified, so it
        // must keep mapping through `typedError` ahead of the plain-403
        // permission fallback.
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 403, headers: ["X-Request-Id": "req-sub-env-403"]),
                try encodeJSON([
                    "error": "Email address is not verified",
                    "code": "email_not_verified"
                ])
            )
        }

        do {
            _ = try await Self.makeAPIClient().subscribeToChangelog(
                email: "user@example.com",
                userToken: UUID().uuidString
            )
            Issue.record("Expected emailNotVerified")
        } catch let error as FeedbackClientError {
            guard case .emailNotVerified(_, let requestId) = error else {
                Issue.record("Expected emailNotVerified, got \(error)")
                return
            }
            #expect(requestId == "req-sub-env-403")
        }
    }
}
