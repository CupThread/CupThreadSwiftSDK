import Foundation
import Testing
@testable import CupThreadFeedback

/// Tests for upload session expiry and lifecycle error mappings on PUT (issue #247, API-13).
///
/// SaaS returns stable, machine-readable lifecycle codes on `PUT /api/v1/uploads/{uploadId}`:
/// - 401 `session_expired` / `session_invalid_or_expired` → `.uploadSessionExpired`
/// - 401 `session_invalid`, 409 `session_not_pending` / `already_uploaded` → `.uploadSessionInvalid`
///
/// These errors must surface as typed errors (not `.unexpectedStatus(401)` or `.authenticationRequired`),
/// keep `X-Request-Id` correlation, and provide curated user-safe copy instructing the user
/// to remove and re-attach rather than displaying HTTP 401 signed-in copy.
@Suite("UploadSessionExpiryErrors", .serialized)
struct UploadSessionExpiryErrorTests {
    private let host = "upload-session-expiry.example.com"
    private var baseURL: URL { URL(string: "https://\(host)")! }

    private func makeSession(maxSizeBytes: Int = 20_000_000) throws -> FeedbackUploadSession {
        let json: [String: Any] = [
            "session": [
                "sessionId": "sess-expiry-1",
                "sessionToken": "stok-expiry-1",
                "expiresAt": "2026-10-08T12:00:00Z",
                "maxFileSizeBytes": maxSizeBytes,
                "maxFiles": 8
            ],
            "files": [[
                "clientFileId": "file-1",
                "uploadId": "upl-expiry-1",
                "uploadUrl": "https://\(host)/api/v1/uploads/upl-expiry-1",
                "maxSizeBytes": maxSizeBytes
            ]]
        ]
        return try JSONDecoder().decode(FeedbackUploadSession.self, from: try encodeJSON(json))
    }

    private func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: baseURL)
    }

    private func makeTempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "cupthread-expiry-test-\(UUID().uuidString).bin")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - 401 session_expired mapping

    @Test func uploadPUT401SessionExpiredThrowsUploadSessionExpired() async throws {
        MockURLProtocol.setHandler(forHost: host) { _ in
            (
                makeHTTPResponse(status: 401, headers: ["X-Request-Id": "req-exp-401"]),
                try encodeJSON([
                    "error": "Session token has expired",
                    "code": "session_expired"
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
            Issue.record("Expected uploadSessionExpired")
        } catch let error as FeedbackClientError {
            guard case .uploadSessionExpired(let message, let requestId) = error else {
                Issue.record("Expected .uploadSessionExpired, got \(error)")
                return
            }
            #expect(message == "Session token has expired")
            #expect(requestId == "req-exp-401")
            #expect(error.requestId == "req-exp-401")
            #expect(error.responseBody == nil)

            let desc = try #require(error.errorDescription)
            let unauthorized = CupThreadStrings.tr("cupthread.error.http_unauthorized")
            #expect(desc != unauthorized)
            #expect(!desc.contains(unauthorized))
            #expect(!desc.contains("Session token has expired"))
            #expect(desc.contains("req-exp-401"))
            #expect(FriendlyError.message(for: error) == desc)
        }
    }

    // MARK: - 401 session_invalid_or_expired mapping

    @Test func uploadPUT401SessionInvalidOrExpiredThrowsUploadSessionExpired() async throws {
        MockURLProtocol.setHandler(forHost: host) { _ in
            (
                makeHTTPResponse(status: 401, headers: ["X-Request-Id": "req-inv-exp-401"]),
                try encodeJSON([
                    "error": "Session token invalid or unknown",
                    "code": "session_invalid_or_expired"
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
            Issue.record("Expected uploadSessionExpired")
        } catch let error as FeedbackClientError {
            guard case .uploadSessionExpired(let message, let requestId) = error else {
                Issue.record("Expected .uploadSessionExpired, got \(error)")
                return
            }
            #expect(message == "Session token invalid or unknown")
            #expect(requestId == "req-inv-exp-401")

            let desc = try #require(error.errorDescription)
            let unauthorized = CupThreadStrings.tr("cupthread.error.http_unauthorized")
            #expect(desc != unauthorized)
            #expect(!desc.contains(unauthorized))
            #expect(!desc.contains("Session token invalid or unknown"))
            #expect(desc.contains("req-inv-exp-401"))
        }
    }

    // MARK: - 401 session_invalid mapping

    @Test func uploadPUT401SessionInvalidThrowsUploadSessionInvalid() async throws {
        MockURLProtocol.setHandler(forHost: host) { _ in
            (
                makeHTTPResponse(status: 401, headers: ["X-Request-Id": "req-inv-401"]),
                try encodeJSON([
                    "error": "Session token invalid",
                    "code": "session_invalid"
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
            Issue.record("Expected uploadSessionInvalid")
        } catch let error as FeedbackClientError {
            guard case .uploadSessionInvalid(let message, let requestId) = error else {
                Issue.record("Expected .uploadSessionInvalid, got \(error)")
                return
            }
            #expect(message == "Session token invalid")
            #expect(requestId == "req-inv-401")
            #expect(error.requestId == "req-inv-401")

            let desc = try #require(error.errorDescription)
            let unauthorized = CupThreadStrings.tr("cupthread.error.http_unauthorized")
            #expect(desc != unauthorized)
            #expect(!desc.contains(unauthorized))
            #expect(!desc.contains("Session token invalid"))
            #expect(desc.contains("req-inv-401"))
        }
    }

    // MARK: - 409 session_not_pending & already_uploaded mapping

    @Test func uploadPUT409SessionNotPendingThrowsUploadSessionInvalid() async throws {
        MockURLProtocol.setHandler(forHost: host) { _ in
            (
                makeHTTPResponse(status: 409, headers: ["X-Request-Id": "req-409-snp"]),
                try encodeJSON([
                    "error": "Session already completed",
                    "code": "session_not_pending"
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
            Issue.record("Expected uploadSessionInvalid")
        } catch let error as FeedbackClientError {
            guard case .uploadSessionInvalid(let message, let requestId) = error else {
                Issue.record("Expected .uploadSessionInvalid, got \(error)")
                return
            }
            #expect(message == "Session already completed")
            #expect(requestId == "req-409-snp")
        }
    }

    @Test func uploadPUT409AlreadyUploadedThrowsUploadSessionInvalid() async throws {
        MockURLProtocol.setHandler(forHost: host) { _ in
            (
                makeHTTPResponse(status: 409, headers: ["X-Request-Id": "req-409-au"]),
                try encodeJSON([
                    "error": "Slot already finalized",
                    "code": "already_uploaded"
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
            Issue.record("Expected uploadSessionInvalid")
        } catch let error as FeedbackClientError {
            guard case .uploadSessionInvalid(let message, let requestId) = error else {
                Issue.record("Expected .uploadSessionInvalid, got \(error)")
                return
            }
            #expect(message == "Slot already finalized")
            #expect(requestId == "req-409-au")
        }
    }

    // MARK: - Streaming fileURL path propagation

    @Test func fileUploadStreamsAndThrowsUploadSessionExpired() async throws {
        MockURLProtocol.setHandler(forHost: host) { _ in
            (
                makeHTTPResponse(status: 401, headers: ["X-Request-Id": "req-file-exp"]),
                try encodeJSON([
                    "error": "Session token has expired",
                    "code": "session_expired"
                ])
            )
        }

        let fixtureURL = try makeTempFile(Data("streaming bytes".utf8))
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let client = makeAPIClient()
        let session = try makeSession()
        do {
            _ = try await client.uploadAttachment(
                fileURL: fixtureURL,
                contentType: "text/plain",
                session: session
            )
            Issue.record("Expected uploadSessionExpired")
        } catch let error as FeedbackClientError {
            guard case .uploadSessionExpired(_, let requestId) = error else {
                Issue.record("Expected .uploadSessionExpired, got \(error)")
                return
            }
            #expect(requestId == "req-file-exp")
        }
    }

    // MARK: - Fallback and regression tests

    @Test func uploadPUT401UnknownCodeFallsThroughToUnexpectedStatus() async throws {
        MockURLProtocol.setHandler(forHost: host) { _ in
            (
                makeHTTPResponse(status: 401, headers: ["X-Request-Id": "req-unknown-401"]),
                try encodeJSON([
                    "error": "Something else unauthorized",
                    "code": "custom_unknown_401"
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
            #expect(code == 401)
            #expect(message == "Something else unauthorized")
            #expect(requestId == "req-unknown-401")
        }
    }

    @Test func uploadPUT429StillMapsToRateLimited() async throws {
        MockURLProtocol.setHandler(forHost: host) { _ in
            (
                makeHTTPResponse(status: 429, headers: ["X-Request-Id": "req-429-rate"]),
                try encodeJSON(["error": "Too many requests"])
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
            Issue.record("Expected rateLimited")
        } catch let error as FeedbackClientError {
            guard case .rateLimited(let message, let requestId) = error else {
                Issue.record("Expected .rateLimited, got \(error)")
                return
            }
            #expect(message == "Too many requests")
            #expect(requestId == "req-429-rate")
        }
    }

    // MARK: - Convenience upload propagation

    @Test func convenienceUploadAttachmentPropagatesUploadSessionExpired() async throws {
        let sessionJSON: [String: Any] = [
            "session": [
                "sessionId": "sess-expiry-1",
                "sessionToken": "stok-expiry-1",
                "expiresAt": "2026-10-08T12:00:00Z",
                "maxFileSizeBytes": 20_000_000,
                "maxFiles": 8
            ],
            "files": [[
                "clientFileId": "file-1",
                "uploadId": "upl-expiry-1",
                "uploadUrl": "https://\(host)/api/v1/uploads/upl-expiry-1",
                "maxSizeBytes": 20_000_000
            ]]
        ]

        MockURLProtocol.setHandler(forHost: host) { request in
            if request.httpMethod == "POST" {
                return (makeHTTPResponse(status: 201), try encodeJSON(sessionJSON))
            }
            return (
                makeHTTPResponse(status: 401, headers: ["X-Request-Id": "req-e2e-exp"]),
                try encodeJSON([
                    "error": "Session token has expired",
                    "code": "session_expired"
                ])
            )
        }

        let client = makeAPIClient()
        do {
            _ = try await client.uploadAttachment(
                data: Data("bytes".utf8),
                filename: "photo.png",
                mimeType: "image/png"
            )
            Issue.record("Expected uploadSessionExpired")
        } catch let error as FeedbackClientError {
            guard case .uploadSessionExpired(_, let requestId) = error else {
                Issue.record("Expected .uploadSessionExpired, got \(error)")
                return
            }
            #expect(requestId == "req-e2e-exp")
        }
    }

    // MARK: - Convenience constructors

    @Test func convenienceConstructorsOmitDetailsByDefault() {
        let expired = FeedbackClientError.uploadSessionExpired()
        #expect(expired == .uploadSessionExpired(message: nil, requestId: nil))
        #expect(expired.requestId == nil)
        #expect(expired.responseBody == nil)
        #expect(expired.errorDescription?.contains("expired") == true)

        let invalid = FeedbackClientError.uploadSessionInvalid()
        #expect(invalid == .uploadSessionInvalid(message: nil, requestId: nil))
        #expect(invalid.requestId == nil)
        #expect(invalid.responseBody == nil)
        #expect(invalid.errorDescription?.contains("invalid") == true)
    }
}
