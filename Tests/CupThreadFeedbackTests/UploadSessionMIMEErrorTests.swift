import Foundation
import Testing
@testable import CupThreadFeedback

/// Tests for session-creation MIME and executable extension error mapping
/// on `POST /api/v1/uploads/sessions` (API-14, #251).
///
/// Disallowed MIME types and executable extensions are rejected at session
/// creation before any bytes are streamed. Both envelopes map to
/// `FeedbackClientError.unsupportedMediaType` with `X-Request-Id` preserved,
/// while raw server error strings stay off user-facing error copy.
@Suite("UploadSessionMIMEErrorTests", .serialized)
struct UploadSessionMIMEErrorTests {
    private let host = "upload-mime-err.example.com"
    private var baseURL: URL { URL(string: "https://\(host)")! }

    private func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: baseURL)
    }

    private func makeUploadCall(
        filename: String = "file.txt",
        contentType: String = "text/plain"
    ) async throws -> FeedbackUploadSession {
        try await makeAPIClient().createUploadSession(
            files: [FeedbackUploadFileSpec(
                clientFileId: "f-1",
                filename: filename,
                contentType: contentType,
                sizeBytes: 128
            )],
            userToken: "tok-test"
        )
    }

    @Test func createUploadSessionMapsUnsupportedMimeTypeWithRequestId() async throws {
        MockURLProtocol.setHandler(forHost: host) { _ in
            (
                makeHTTPResponse(status: 400, headers: ["X-Request-Id": "req-mime-1"]),
                try encodeJSON([
                    "error": "Declared MIME type application/pdf is not supported",
                    "code": "unsupported_mime_type"
                ])
            )
        }

        do {
            _ = try await makeUploadCall(contentType: "application/pdf")
            Issue.record("Expected unsupportedMediaType error")
        } catch let error as FeedbackClientError {
            guard case .unsupportedMediaType(let message, let requestId) = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(message == "Declared MIME type application/pdf is not supported")
            #expect(requestId == "req-mime-1")
            #expect(error.requestId == "req-mime-1")

            let description = try #require(error.errorDescription)
            #expect(description == "That image type isn't supported. Please attach a PNG, JPEG, WebP, or GIF. (request id: req-mime-1)")
            #expect(!description.contains("application/pdf"))
            #expect(error.responseBody == nil)
            #expect(FriendlyError.message(for: error) == description)
        }
    }

    @Test func createUploadSessionMapsUnsupportedMimeTypeWithoutRequestId() async throws {
        MockURLProtocol.setHandler(forHost: host) { _ in
            (
                makeHTTPResponse(status: 400),
                try encodeJSON([
                    "error": "Disallowed MIME type",
                    "code": "unsupported_mime_type"
                ])
            )
        }

        do {
            _ = try await makeUploadCall(contentType: "application/zip")
            Issue.record("Expected unsupportedMediaType error")
        } catch let error as FeedbackClientError {
            guard case .unsupportedMediaType(let message, let requestId) = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(message == "Disallowed MIME type")
            #expect(requestId == nil)
            #expect(error.requestId == nil)

            let description = try #require(error.errorDescription)
            #expect(description == "That image type isn't supported. Please attach a PNG, JPEG, WebP, or GIF.")
            #expect(!description.contains("Disallowed"))
            #expect(error.responseBody == nil)
        }
    }

    @Test func createUploadSessionMapsExecutableExtensionProhibitedWithRequestId() async throws {
        MockURLProtocol.setHandler(forHost: host) { _ in
            (
                makeHTTPResponse(status: 400, headers: ["X-Request-Id": "req-exec-2"]),
                try encodeJSON([
                    "error": "Filename extension .sh is on the prohibited executable list",
                    "code": "executable_extension_prohibited"
                ])
            )
        }

        do {
            _ = try await makeUploadCall(filename: "run.sh", contentType: "application/x-sh")
            Issue.record("Expected unsupportedMediaType error")
        } catch let error as FeedbackClientError {
            guard case .unsupportedMediaType(let message, let requestId) = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(message == "Filename extension .sh is on the prohibited executable list")
            #expect(requestId == "req-exec-2")
            #expect(error.requestId == "req-exec-2")

            let description = try #require(error.errorDescription)
            #expect(description == "That image type isn't supported. Please attach a PNG, JPEG, WebP, or GIF. (request id: req-exec-2)")
            #expect(!description.contains("prohibited"))
            #expect(!description.contains(".sh"))
            #expect(error.responseBody == nil)
            #expect(FriendlyError.message(for: error) == description)
        }
    }

    @Test func createUploadSessionPreservesUnexpectedStatusForUnknown400Codes() async throws {
        MockURLProtocol.setHandler(forHost: host) { _ in
            (
                makeHTTPResponse(status: 400, headers: ["X-Request-Id": "req-unknown-400"]),
                try encodeJSON([
                    "error": "Field 'foo' is invalid",
                    "code": "unknown_validation_error"
                ])
            )
        }

        do {
            _ = try await makeUploadCall()
            Issue.record("Expected unexpectedStatus error")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, let message, let requestId) = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(code == 400)
            #expect(message == "Field 'foo' is invalid")
            #expect(requestId == "req-unknown-400")
            #expect(error.requestId == "req-unknown-400")
        }
    }

    @Test func convenienceUploadAttachmentPropagatesUnsupportedMediaTypeOnSessionCreate() async throws {
        MockURLProtocol.setHandler(forHost: host) { _ in
            (
                makeHTTPResponse(status: 400, headers: ["X-Request-Id": "req-convenience-1"]),
                try encodeJSON([
                    "error": "Executable extensions prohibited",
                    "code": "executable_extension_prohibited"
                ])
            )
        }

        let client = makeAPIClient()
        do {
            _ = try await client.uploadAttachment(
                data: Data("echo hello".utf8),
                filename: "script.command",
                mimeType: "application/x-sh",
                userToken: "tok-test"
            )
            Issue.record("Expected unsupportedMediaType error")
        } catch let error as FeedbackClientError {
            guard case .unsupportedMediaType(let message, let requestId) = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(message == "Executable extensions prohibited")
            #expect(requestId == "req-convenience-1")
        }
    }

    @Test func uploadPut415StillSurfacesUnsupportedMediaTypeRegression() async throws {
        let sessionJSON: [String: Any] = [
            "session": [
                "sessionId": "sess-reg-1",
                "sessionToken": "stok-abc",
                "expiresAt": "2026-09-13T12:00:00Z",
                "maxFileSizeBytes": 20_000_000,
                "maxFiles": 8
            ],
            "files": [
                [
                    "uploadId": "upl-reg-1",
                    "clientFileId": "file-1",
                    "filename": "image.png",
                    "contentType": "image/png",
                    "maxSizeBytes": 1024,
                    "uploadUrl": "https://\(host)/api/v1/uploads/upl-reg-1"
                ]
            ]
        ]

        MockURLProtocol.setHandler(forHost: host) { request in
            if request.httpMethod == "POST" {
                return (makeHTTPResponse(status: 201), try encodeJSON(sessionJSON))
            }
            return (
                makeHTTPResponse(status: 415, headers: ["X-Request-Id": "req-put-415"]),
                try encodeJSON(["error": "Magic bytes do not match declared MIME"])
            )
        }

        let client = makeAPIClient()
        do {
            _ = try await client.uploadAttachment(
                data: Data([0x00, 0x01, 0x02]),
                filename: "image.png",
                mimeType: "image/png",
                userToken: "tok-test"
            )
            Issue.record("Expected unsupportedMediaType error on PUT 415")
        } catch let error as FeedbackClientError {
            guard case .unsupportedMediaType(let message, let requestId) = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(message == "Magic bytes do not match declared MIME")
            #expect(requestId == "req-put-415")
        }
    }
}
