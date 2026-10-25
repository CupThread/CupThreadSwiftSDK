import Foundation
import Testing
@testable import CupThreadFeedback

/// Tests for the upload-session bearer-token grammar (#593).
///
/// `sessionToken` is server-controlled: it arrives in the
/// `POST /api/v1/uploads/sessions` response body and is replayed by the
/// client into the `Authorization` header of the slot PUT. It is the last
/// header interpolation sink with no validation — the same trust class as
/// the response-echoed `X-Request-Id` (SEC-12), while every caller-supplied
/// token sink was already hardened (SEC-25/SEC-26/SEC-30, #433, #435,
/// #497). Enforcement lives at the decode boundary
/// (`FeedbackUploadSession.Info.init(from:)`), so an invalid token fails
/// closed as ``FeedbackClientError/invalidResponse`` before any upload PUT
/// is built, and can never propagate to a second consumer.
///
/// End-to-end tests each use their own mock host so they cannot stomp (or
/// be stomped by) suites that share the default `test.example.com` handler.
@Suite("UploadSessionTokenValidation", .serialized)
struct UploadSessionTokenValidationTests {

    // MARK: Grammar-level matrix

    @Test func grammarAcceptsValidOpaqueToken() {
        let token = String(repeating: "aB3z+/=_-0", count: 20) // 200 chars, base64-ish
        #expect(token.count == 200)
        #expect(UploadSessionTokenGrammar.isValid(token))
        #expect(UploadSessionTokenGrammar.validated(token) == token)
    }

    @Test func grammarTrimsPaddedToken() {
        #expect(UploadSessionTokenGrammar.validated("  stok-abc\t") == "stok-abc")
        #expect(UploadSessionTokenGrammar.validated("\n stok-abc \n") == "stok-abc")
    }

    @Test func grammarRejectsBlankAndEmptyTokens() {
        #expect(!UploadSessionTokenGrammar.isValid(""))
        #expect(!UploadSessionTokenGrammar.isValid("   "))
        #expect(!UploadSessionTokenGrammar.isValid(" \t\n "))
        #expect(UploadSessionTokenGrammar.validated("   ") == nil)
    }

    @Test func grammarRejectsNewlineBearingTokens() {
        let rejected = [
            "abc\r\nX-Evil: 1\r\n\r\nGET /admin HTTP/1.1",
            "abc\ndef",
            "abc\rdef",
            "abc\u{2028}def", // line separator
            "abc\u{0085}def" // next line
        ]
        for token in rejected {
            #expect(!UploadSessionTokenGrammar.isValid(token), "Expected rejection: \(token.debugDescription)")
        }
    }

    @Test func grammarRejectsControlCharacterTokens() {
        let rejected = [
            "abc\u{0}def",
            "abc\u{1F}def",
            "abc\u{7F}def",
            "abc\u{9B}def" // C1 control
        ]
        for token in rejected {
            #expect(!UploadSessionTokenGrammar.isValid(token), "Expected rejection: \(token.debugDescription)")
        }
    }

    @Test func grammarRejectsOversizeTokens() {
        #expect(UploadSessionTokenGrammar.maxByteCount == 1024)
        let atCap = String(repeating: "a", count: UploadSessionTokenGrammar.maxByteCount)
        #expect(atCap.utf8.count == UploadSessionTokenGrammar.maxByteCount)
        #expect(UploadSessionTokenGrammar.isValid(atCap))

        let overCap = String(repeating: "a", count: UploadSessionTokenGrammar.maxByteCount + 1)
        #expect(!UploadSessionTokenGrammar.isValid(overCap))
        #expect(UploadSessionTokenGrammar.validated(overCap) == nil)
    }

    @Test func grammarLengthCapCountsUTF8BytesNotGraphemes() {
        // 1024 Characters — under a grapheme cap — whose UTF-8 encoding is
        // 3 KiB: the byte cap must bound the header's wire size, not the
        // cluster count.
        let diacriticLoaded = String(repeating: "e\u{0301}", count: UploadSessionTokenGrammar.maxByteCount)
        #expect(diacriticLoaded.count == UploadSessionTokenGrammar.maxByteCount)
        #expect(diacriticLoaded.utf8.count == 3 * UploadSessionTokenGrammar.maxByteCount)
        #expect(!UploadSessionTokenGrammar.isValid(diacriticLoaded))
    }

    // MARK: Decode-boundary enforcement

    private func makeSessionJSON(sessionToken: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "session": [
                "sessionId": "sess-1",
                "sessionToken": sessionToken,
                "expiresAt": "2026-09-30T12:00:00Z",
                "maxFileSizeBytes": 20_000_000,
                "maxFiles": 8
            ],
            "files": [[
                "clientFileId": "file-1",
                "uploadId": "upl-1",
                "uploadUrl": "/api/v1/uploads/upl-1",
                "maxSizeBytes": 20_000_000
            ]]
        ])
    }

    /// Decodes a session body carrying `sessionToken` and asserts the model
    /// refuses it at the decode boundary — the failure `decodeSuccess` maps
    /// to the typed ``FeedbackClientError/invalidResponse``.
    private func assertDecodeRejects(sessionToken: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let data = try makeSessionJSON(sessionToken: sessionToken)
        do {
            _ = try JSONDecoder().decode(FeedbackUploadSession.self, from: data)
            Issue.record("Expected the sessionToken to be rejected at the decode boundary", sourceLocation: sourceLocation)
        } catch is DecodingError {
            // Expected: the grammar refusal surfaces as a data-corrupted error.
        }
    }

    @Test func decodeRejectsCRLFSessionToken() throws {
        try assertDecodeRejects(sessionToken: "abc\r\nX-Evil: 1")
    }

    @Test func decodeRejectsLoneNewlineSessionToken() throws {
        try assertDecodeRejects(sessionToken: "abc\ndef")
    }

    @Test func decodeRejectsControlCharacterSessionToken() throws {
        try assertDecodeRejects(sessionToken: "abc\u{0}def")
    }

    @Test func decodeRejectsOversizeSessionToken() throws {
        try assertDecodeRejects(
            sessionToken: String(repeating: "a", count: UploadSessionTokenGrammar.maxByteCount + 1)
        )
    }

    @Test func decodeRejectsByteOversizeCombiningMarkSessionToken() throws {
        try assertDecodeRejects(
            sessionToken: String(repeating: "e\u{0301}", count: UploadSessionTokenGrammar.maxByteCount)
        )
    }

    @Test func decodeTrimsPaddedSessionToken() throws {
        let data = try makeSessionJSON(sessionToken: "  stok-abc  ")
        let session = try JSONDecoder().decode(FeedbackUploadSession.self, from: data)
        #expect(session.session.sessionToken == "stok-abc")
    }

    @Test func decodePreservesValidSessionTokenByteIdentically() throws {
        let token = String(repeating: "QmFzZTY0", count: 25) // 200 chars
        let data = try makeSessionJSON(sessionToken: token)
        let session = try JSONDecoder().decode(FeedbackUploadSession.self, from: data)
        #expect(session.session.sessionToken == token)
    }

    // MARK: End-to-end: the PUT is never built for an invalid token

    private let uploadedJSON: [String: Any] = [
        "uploadId": "upl-1",
        "clientFileId": "file-1",
        "filename": "f.png",
        "contentType": "image/png",
        "sizeBytes": 5,
        "stored": true,
        "downloadUrl": "/api/v1/attachments/upl-1"
    ]

    /// Installs a handler serving `sessionToken` on the session POST and a
    /// successful upload PUT, recording every intercepted request.
    private func installHandlers(host: String, sessionToken: String) -> CaptureBox<[URLRequest]> {
        let requests = CaptureBox<[URLRequest]>()
        MockURLProtocol.setHandler(forHost: host) { [uploadedJSON] request in
            requests.value = (requests.value ?? []) + [request]
            if request.url?.path == "/api/v1/uploads/sessions" {
                return (
                    makeHTTPResponse(status: 201, url: request.url!),
                    try encodeJSON([
                        "session": [
                            "sessionId": "sess-1",
                            "sessionToken": sessionToken,
                            "expiresAt": "2026-09-30T12:00:00Z",
                            "maxFileSizeBytes": 20_000_000,
                            "maxFiles": 8
                        ],
                        "files": [[
                            "clientFileId": "file-1",
                            "uploadId": "upl-1",
                            "uploadUrl": "https://\(host)/api/v1/uploads/upl-1",
                            "maxSizeBytes": 20_000_000
                        ]]
                    ])
                )
            }
            return (
                makeHTTPResponse(status: 200, url: request.url!),
                try encodeJSON(uploadedJSON)
            )
        }
        return requests
    }

    /// Runs the full upload flow and asserts the server-controlled token
    /// fails closed as `.invalidResponse` with the session POST as the only
    /// dispatched request — the slot PUT (attachment bytes and bearer
    /// included) is never created.
    private func assertUploadFailsClosed(sessionToken: String, host: String) async throws {
        let requests = installHandlers(host: host, sessionToken: sessionToken)
        let client = makeClient(baseURL: URL(string: "https://\(host)")!)

        do {
            _ = try await client.uploadAttachment(
                data: Data("attachment bytes".utf8),
                filename: "f.png",
                mimeType: "image/png",
                userToken: nil
            )
            Issue.record("Expected the invalid sessionToken to fail the upload")
        } catch let error as FeedbackClientError {
            #expect(error == .invalidResponse)
        }

        let dispatched = try #require(requests.value)
        #expect(dispatched.count == 1, "Only the session POST may be dispatched, saw \(dispatched.count)")
        #expect(dispatched.first?.httpMethod == "POST")
        #expect(dispatched.first?.url?.path == "/api/v1/uploads/sessions")
    }

    @Test func uploadFailsClosedOnCRLFSessionToken() async throws {
        try await assertUploadFailsClosed(
            sessionToken: "abc\r\nX-Evil: 1\r\n\r\nGET /admin HTTP/1.1",
            host: "upload-token-crlf.example.com"
        )
    }

    @Test func uploadFailsClosedOnLoneNewlineSessionToken() async throws {
        try await assertUploadFailsClosed(
            sessionToken: "abc\ndef",
            host: "upload-token-lf.example.com"
        )
    }

    @Test func uploadFailsClosedOnControlCharacterSessionToken() async throws {
        try await assertUploadFailsClosed(
            sessionToken: "abc\u{0}def",
            host: "upload-token-nul.example.com"
        )
    }

    @Test func uploadFailsClosedOnOversizeSessionToken() async throws {
        try await assertUploadFailsClosed(
            sessionToken: String(repeating: "a", count: UploadSessionTokenGrammar.maxByteCount + 1),
            host: "upload-token-oversize.example.com"
        )
    }

    // MARK: End-to-end: valid tokens reach the Authorization header intact

    @Test func uploadSendsPaddedSessionTokenTrimmed() async throws {
        let requests = installHandlers(host: "upload-token-padded.example.com", sessionToken: "  stok-abc  ")
        let client = makeClient(baseURL: URL(string: "https://upload-token-padded.example.com")!)

        _ = try await client.uploadAttachment(
            data: Data("hello".utf8), filename: "f.png", mimeType: "image/png", userToken: nil
        )

        let dispatched = try #require(requests.value)
        let putRequest = try #require(dispatched.first { $0.httpMethod == "PUT" })
        #expect(putRequest.value(forHTTPHeaderField: "Authorization") == "Bearer stok-abc")
    }

    @Test func uploadSendsValidSessionTokenByteIdentically() async throws {
        let token = String(repeating: "QmFzZTY0", count: 25) // 200 chars, base64-ish
        let requests = installHandlers(host: "upload-token-valid.example.com", sessionToken: token)
        let client = makeClient(baseURL: URL(string: "https://upload-token-valid.example.com")!)

        _ = try await client.uploadAttachment(
            data: Data("hello".utf8), filename: "f.png", mimeType: "image/png", userToken: nil
        )

        let dispatched = try #require(requests.value)
        let putRequest = try #require(dispatched.first { $0.httpMethod == "PUT" })
        #expect(putRequest.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
    }
}
