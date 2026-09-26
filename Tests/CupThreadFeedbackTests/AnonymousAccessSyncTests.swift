import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("AnonymousAccessSync", .serialized)
struct AnonymousAccessSyncTests {
    static let apiHost = "anonymous-sync.example.com"

    static func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    @Test func fetchVersionsMapsAuthenticationRequiredEnvelopeToTypedError() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 401),
                try encodeJSON([
                    "error": "Sign in required to view versions",
                    "code": "authentication_required"
                ])
            )
        }

        do {
            _ = try await Self.makeAPIClient().fetchVersions()
            Issue.record("Expected authenticationRequired")
        } catch let error as FeedbackClientError {
            #expect(error == .authenticationRequired)
        }
    }

    @Test func fetchColumnsMapsAuthenticationRequiredEnvelopeToTypedError() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 401),
                try encodeJSON([
                    "error": "Sign in required to view columns",
                    "code": "authentication_required"
                ])
            )
        }

        do {
            _ = try await Self.makeAPIClient().fetchColumns()
            Issue.record("Expected authenticationRequired")
        } catch let error as FeedbackClientError {
            #expect(error == .authenticationRequired)
        }
    }

    @Test func fetchCommentsMapsAuthenticationRequiredEnvelopeToTypedError() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 401),
                try encodeJSON([
                    "error": "Sign in required to view comments",
                    "code": "authentication_required"
                ])
            )
        }

        do {
            _ = try await Self.makeAPIClient().fetchComments(featureRequestId: "fr-123")
            Issue.record("Expected authenticationRequired")
        } catch let error as FeedbackClientError {
            #expect(error == .authenticationRequired)
        }
    }

    @Test func fetchCommentsMaps404ToCommentsUnavailable() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 404, headers: ["X-Request-Id": "req-comment-404"]),
                try encodeJSON(["error": "Comments are disabled for this feature request"])
            )
        }

        do {
            _ = try await Self.makeAPIClient().fetchComments(featureRequestId: "fr-123")
            Issue.record("Expected commentsUnavailable")
        } catch let error as FeedbackClientError {
            guard case .commentsUnavailable(let message, let requestId) = error else {
                Issue.record("Expected commentsUnavailable, got \(error)")
                return
            }
            #expect(message == "Comments are disabled for this feature request")
            #expect(requestId == "req-comment-404")
            #expect(error.requestId == "req-comment-404")
            #expect(error.responseBody == nil)
            let expectedMsg = "Comments are not available for this feature request. (request id: req-comment-404)"
            #expect(error.errorDescription == expectedMsg)
            #expect(FriendlyError.message(for: error) == expectedMsg)
        }

        do {
            _ = try await Self.makeAPIClient().fetchComments(featureRequestId: "fr-123", limit: 50)
            Issue.record("Expected commentsUnavailable on paginated fetch")
        } catch let error as FeedbackClientError {
            guard case .commentsUnavailable = error else {
                Issue.record("Expected commentsUnavailable, got \(error)")
                return
            }
        }
    }

    @Test func subscribeToChangelogMapsAuthenticationRequiredEnvelopeToTypedError() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 401),
                try encodeJSON([
                    "error": "Sign in required to subscribe",
                    "code": "authentication_required"
                ])
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

    @Test func subscribeToChangelogMapsEmailNotVerifiedToTypedError() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 403, headers: ["X-Request-Id": "req-sub-403"]),
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
            guard case .emailNotVerified(let message, let requestId) = error else {
                Issue.record("Expected emailNotVerified, got \(error)")
                return
            }
            #expect(message == "Email address is not verified")
            #expect(requestId == "req-sub-403")
            #expect(error.requestId == "req-sub-403")
            #expect(error.responseBody == nil)
            let expectedMsg = "Please use your signed-in account email address to subscribe. (request id: req-sub-403)"
            #expect(error.errorDescription == expectedMsg)
            #expect(FriendlyError.message(for: error) == expectedMsg)
        }
    }

    @Test func convenienceConstructorsInitializeWithoutRequestId() {
        let commentsError = FeedbackClientError.commentsUnavailable(message: "unavailable")
        #expect(commentsError == .commentsUnavailable(message: "unavailable", requestId: nil))
        #expect(commentsError.requestId == nil)
        #expect(commentsError.errorDescription == "Comments are not available for this feature request.")

        let emailError = FeedbackClientError.emailNotVerified(message: "not verified")
        #expect(emailError == .emailNotVerified(message: "not verified", requestId: nil))
        #expect(emailError.requestId == nil)
        #expect(emailError.errorDescription == "Please use your signed-in account email address to subscribe.")
    }
}
