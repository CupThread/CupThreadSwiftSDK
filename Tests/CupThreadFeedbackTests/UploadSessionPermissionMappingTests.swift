import Foundation
import Testing
@testable import CupThreadFeedback

/// Tests for permission-error mapping on `POST /api/v1/uploads/sessions`
/// (`createUploadSession`). The route denies before creating a session —
/// `401 authentication_required` when `allowAnonymousFeedback` is off, and a
/// bare, code-less `403` when `allowPublic` is off — so it must map those to
/// `.authenticationRequired` / `.forbidden` like the other intake endpoints
/// (#239), while Turnstile-shaped 403s keep their typed path.
///
/// The suite uses its own mock host so it cannot stomp (or be stomped by)
/// suites that share the default `test.example.com` handler.
@Suite("UploadSessionPermissionMapping", .serialized)
struct UploadSessionPermissionMappingTests {
    private let host = "upload-perm.example.com"
    private var baseURL: URL { URL(string: "https://\(host)")! }

    private func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: baseURL)
    }

    private func makeUploadCall() async throws -> FeedbackUploadSession {
        try await makeAPIClient().createUploadSession(
            files: [FeedbackUploadFileSpec(clientFileId: "f", filename: "f.txt", contentType: "text/plain", sizeBytes: 4)],
            userToken: "tok"
        )
    }

    @Test func createUploadSessionMapsCodeless403ToForbidden() async throws {
        // allowPublic turned off in the console: the uploads-sessions route
        // denies with a bare 403 (no machine code) before creating a session.
        // #239: this must surface as `.forbidden`, not `.unexpectedStatus`.
        MockURLProtocol.setHandler(forHost: host) { _ in
            (
                makeHTTPResponse(status: 403, headers: ["X-Request-Id": "req-upload-403"]),
                try encodeJSON(["error": "Public feedback is disabled for this app"])
            )
        }
        do {
            _ = try await makeUploadCall()
            Issue.record("Expected forbidden")
        } catch let error as FeedbackClientError {
            guard case .forbidden(let message, let requestId) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(message == "Public feedback is disabled for this app")
            #expect(requestId == "req-upload-403")
            // Surfaces routing through FriendlyError show curated permission
            // copy — the raw server text and generic request-failed copy both
            // stay out of the UI.
            let display = FriendlyError.message(for: error)
            #expect(display == CupThreadStrings.tr("cupthread.error.forbidden") + " (request id: req-upload-403)")
            #expect(!display.contains("Public feedback is disabled"))
        }
    }

    @Test func createUploadSessionKeepsTurnstileRejectionOnTypedPath() async throws {
        // A Turnstile-shaped 403 on the same route must keep mapping through
        // typedError (which runs before the permission branch), regardless of
        // mapsPermissionErrors. #239 regression guard.
        MockURLProtocol.setHandler(forHost: host) { _ in
            (
                makeHTTPResponse(status: 403, headers: ["X-Request-Id": "req-upload-turnstile"]),
                try encodeJSON(["error": "Human verification failed", "code": "turnstile_verification_failed"])
            )
        }
        do {
            _ = try await makeUploadCall()
            Issue.record("Expected turnstileRequired")
        } catch let error as FeedbackClientError {
            guard case .turnstileRequired(let message, let requestId) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(message == "Human verification failed")
            #expect(requestId == "req-upload-turnstile")
        }
    }

    @Test func createUploadSessionMaps401AuthenticationRequiredToAuthenticationRequired() async throws {
        // allowAnonymousFeedback turned off: the uploads-sessions route
        // answers 401 authentication_required before any permission check.
        MockURLProtocol.setHandler(forHost: host) { _ in
            (
                makeHTTPResponse(status: 401),
                try encodeJSON(["error": "Sign in required", "code": "authentication_required"])
            )
        }
        do {
            _ = try await makeUploadCall()
            Issue.record("Expected authenticationRequired")
        } catch let error as FeedbackClientError {
            #expect(error == .authenticationRequired)
        }
    }
}
