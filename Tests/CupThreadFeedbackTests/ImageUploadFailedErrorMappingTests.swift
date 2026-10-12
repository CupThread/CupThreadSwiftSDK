import Foundation
import Testing
@testable import CupThreadFeedback

/// Tests for the stable `image_upload_failed` storage-failure envelope
/// (issue #401, API sync): an unexpected server-side storage error (R2 /
/// Cloudflare Images / D1) behind an upload intake answers HTTP 500 with the
/// provider-agnostic body `{ "error": "Image upload failed. Please try
/// again.", "code": "image_upload_failed" }`. The envelope must map to the
/// typed `.imageUploadFailed` case — not `.unexpectedStatus(500)` — so hosts
/// can machine-match it for retry UX, while any other 500 keeps carrying its
/// raw body for diagnostics via `.unexpectedStatus`.
@Suite("ImageUploadFailedErrors", .serialized)
struct ImageUploadFailedErrorMappingTests {
    private let host = "upload-image-failed.example.com"
    private var baseURL: URL { URL(string: "https://\(host)")! }

    private func makeSession() throws -> FeedbackUploadSession {
        let json: [String: Any] = [
            "session": [
                "sessionId": "sess-imagefail-1",
                "sessionToken": "stok-imagefail-1",
                "expiresAt": "2026-10-08T12:00:00Z",
                "maxFileSizeBytes": 20_000_000,
                "maxFiles": 8
            ],
            "files": [[
                "clientFileId": "file-1",
                "uploadId": "upl-imagefail-1",
                "uploadUrl": "https://\(host)/api/v1/uploads/upl-imagefail-1",
                "maxSizeBytes": 20_000_000
            ]]
        ]
        return try JSONDecoder().decode(FeedbackUploadSession.self, from: try encodeJSON(json))
    }

    private func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: baseURL)
    }

    // MARK: - PUT slot upload mapping

    @Test func uploadPUT500ImageUploadFailedThrowsImageUploadFailed() async throws {
        MockURLProtocol.setHandler(forHost: host) { _ in
            (
                makeHTTPResponse(status: 500, headers: ["X-Request-Id": "req-imgfail-500"]),
                try encodeJSON([
                    "error": "Image upload failed. Please try again.",
                    "code": "image_upload_failed"
                ])
            )
        }

        let client = makeAPIClient()
        let session = try makeSession()
        do {
            _ = try await client.uploadAttachment(
                data: Data("test".utf8),
                contentType: "text/plain",
                session: session
            )
            Issue.record("Expected imageUploadFailed")
        } catch let error as FeedbackClientError {
            guard case .imageUploadFailed(let message, let requestId) = error else {
                Issue.record("Expected .imageUploadFailed, got \(error)")
                return
            }
            #expect(message == "Image upload failed. Please try again.")
            #expect(requestId == "req-imgfail-500")
            #expect(error.requestId == "req-imgfail-500")
            // The stable body is diagnostics-free, so nothing is re-exposed
            // through `responseBody`.
            #expect(error.responseBody == nil)

            let desc = try #require(error.errorDescription)
            #expect(desc == CupThreadStrings.tr("cupthread.error.image_upload_failed") + " (request id: req-imgfail-500)")
            #expect(!desc.contains("internal account acct-sentinel"))
            #expect(desc.contains("req-imgfail-500"))
            #expect(FriendlyError.message(for: error) == desc)
        }
    }

    // MARK: - POST upload session mapping

    @Test func uploadSessionPOST500ImageUploadFailedThrowsImageUploadFailed() async throws {
        // The mapping lives in the shared envelope plumbing, so the same
        // stable body maps on every upload intake route, not just the slot PUT.
        MockURLProtocol.setHandler(forHost: host) { _ in
            (
                makeHTTPResponse(status: 500, headers: ["X-Request-Id": "req-imgfail-sess"]),
                try encodeJSON([
                    "error": "Image upload failed. Please try again.",
                    "code": "image_upload_failed"
                ])
            )
        }

        do {
            _ = try await makeAPIClient().createUploadSession(
                files: [FeedbackUploadFileSpec(clientFileId: "f", filename: "f.txt", contentType: "text/plain", sizeBytes: 4)],
                userToken: "tok"
            )
            Issue.record("Expected imageUploadFailed")
        } catch let error as FeedbackClientError {
            guard case .imageUploadFailed(let message, let requestId) = error else {
                Issue.record("Expected .imageUploadFailed, got \(error)")
                return
            }
            #expect(message == "Image upload failed. Please try again.")
            #expect(requestId == "req-imgfail-sess")
        }
    }

    // MARK: - Fallback for other 500s

    @Test func uploadPUT500WithUnknownCodeFallsThroughToUnexpectedStatus() async throws {
        // Only the stable `image_upload_failed` pairing is typed; every other
        // 500 keeps its raw body on `.unexpectedStatus` for diagnostics.
        MockURLProtocol.setHandler(forHost: host) { _ in
            (
                makeHTTPResponse(status: 500, headers: ["X-Request-Id": "req-unknown-500"]),
                try encodeJSON([
                    "error": "internal account acct-sentinel not authorized (ray-sentinel)",
                    "code": "storage_provider_unavailable"
                ])
            )
        }

        let client = makeAPIClient()
        let session = try makeSession()
        do {
            _ = try await client.uploadAttachment(
                data: Data("test".utf8),
                contentType: "text/plain",
                session: session
            )
            Issue.record("Expected unexpectedStatus")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, let message, let requestId) = error else {
                Issue.record("Expected .unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 500)
            #expect(message.contains("acct-sentinel"))
            #expect(requestId == "req-unknown-500")
        }
    }

    @Test func uploadPUT500WithNonJSONBodyFallsThroughToUnexpectedStatus() async throws {
        MockURLProtocol.setHandler(forHost: host) { _ in
            (
                makeHTTPResponse(status: 500, headers: ["X-Request-Id": "req-html-500"]),
                Data("<html>gateway error</html>".utf8)
            )
        }

        let client = makeAPIClient()
        let session = try makeSession()
        do {
            _ = try await client.uploadAttachment(
                data: Data("test".utf8),
                contentType: "text/plain",
                session: session
            )
            Issue.record("Expected unexpectedStatus")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, let message, _) = error else {
                Issue.record("Expected .unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 500)
            #expect(message.contains("gateway error"))
        }
    }

    // MARK: - End-to-end convenience propagation

    @Test func convenienceUploadAttachmentPropagatesImageUploadFailed() async throws {
        let sessionJSON: [String: Any] = [
            "session": [
                "sessionId": "sess-imagefail-1",
                "sessionToken": "stok-imagefail-1",
                "expiresAt": "2026-10-08T12:00:00Z",
                "maxFileSizeBytes": 20_000_000,
                "maxFiles": 8
            ],
            "files": [[
                "clientFileId": "file-1",
                "uploadId": "upl-imagefail-1",
                "uploadUrl": "https://\(host)/api/v1/uploads/upl-imagefail-1",
                "maxSizeBytes": 20_000_000
            ]]
        ]

        MockURLProtocol.setHandler(forHost: host) { request in
            if request.httpMethod == "POST" {
                return (makeHTTPResponse(status: 201), try encodeJSON(sessionJSON))
            }
            return (
                makeHTTPResponse(status: 500, headers: ["X-Request-Id": "req-e2e-imgfail"]),
                try encodeJSON([
                    "error": "Image upload failed. Please try again.",
                    "code": "image_upload_failed"
                ])
            )
        }

        do {
            _ = try await makeAPIClient().uploadAttachment(
                data: Data("bytes".utf8),
                filename: "photo.png",
                mimeType: "image/png"
            )
            Issue.record("Expected imageUploadFailed")
        } catch let error as FeedbackClientError {
            guard case .imageUploadFailed(_, let requestId) = error else {
                Issue.record("Expected .imageUploadFailed, got \(error)")
                return
            }
            #expect(requestId == "req-e2e-imgfail")
        }
    }

    // MARK: - Convenience constructor

    @Test func convenienceConstructorOmitsDetailsByDefault() {
        let failed = FeedbackClientError.imageUploadFailed()
        #expect(failed == .imageUploadFailed(message: nil, requestId: nil))
        #expect(failed.requestId == nil)
        #expect(failed.responseBody == nil)
        #expect(failed.errorDescription?.contains("failed") == true)
    }
}
