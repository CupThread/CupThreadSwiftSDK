import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Relative URL query preservation tests (API-22)

@Suite("FeedbackUploadRelativeURLQueryTests", .serialized)
struct FeedbackUploadRelativeURLQueryTests {
    private let host = "relative-query-tests.example.com"

    private let sessionJSON: [String: Any] = [
        "session": [
            "sessionId": "sess-1",
            "sessionToken": "stok-abc",
            "expiresAt": "2026-09-30T12:00:00Z",
            "maxFileSizeBytes": 20_000_000,
            "maxFiles": 8
        ],
        "files": [[
            "clientFileId": "file-1",
            "uploadId": "upl-1",
            "uploadUrl": "/api/v1/uploads/relative-slot-123?sig=test_signature&expires=1700000000",
            "maxSizeBytes": 20_000_000
        ]]
    ]

    private let uploadedJSON: [String: Any] = [
        "uploadId": "upl-1",
        "clientFileId": "file-1",
        "filename": "f.png",
        "contentType": "image/png",
        "sizeBytes": 5,
        "stored": true,
        "downloadUrl": "/api/v1/uploads/upl-1/download?token=secret_token"
    ]

    @Test func uploadURLPreservesQueryParametersOnRelativePaths() throws {
        let client = makeClient(baseURL: URL(string: "https://api.cupthread.com")!)
        let relativeSlotURL = "/api/v1/uploads/upl_123?sig=test_signature&expires=1700000000"

        let resolved = try client.uploadURL(from: relativeSlotURL)

        #expect(resolved.host == "api.cupthread.com")
        #expect(resolved.path == "/api/v1/uploads/upl_123")
        #expect(resolved.query == "sig=test_signature&expires=1700000000")
        #expect(!resolved.absoluteString.contains("%3F"))

        let bareRelativeSlotURL = "api/v1/uploads/upl_456?sig=bare_signature&expires=1700000001"
        let bareResolved = try client.uploadURL(from: bareRelativeSlotURL)
        #expect(bareResolved.host == "api.cupthread.com")
        #expect(bareResolved.path == "/api/v1/uploads/upl_456")
        #expect(bareResolved.query == "sig=bare_signature&expires=1700000001")
        #expect(!bareResolved.absoluteString.contains("%3F"))
    }

    @Test func resolvedDownloadURLPreservesQueryParametersOnRelativePaths() throws {
        let client = makeClient(baseURL: URL(string: "https://api.cupthread.com")!)
        let relativeDownloadURL = "/api/v1/uploads/upl_123/download?token=secret_token"

        let resolved = client.resolvedDownloadURL(from: relativeDownloadURL)
        let unwrapped = try #require(resolved)

        #expect(unwrapped.host == "api.cupthread.com")
        #expect(unwrapped.path == "/api/v1/uploads/upl_123/download")
        #expect(unwrapped.query == "token=secret_token")
        #expect(!unwrapped.absoluteString.contains("%3F"))

        let bareRelativeDownloadURL = "api/v1/uploads/upl_456/download?token=bare_token"
        let bareResolved = client.resolvedDownloadURL(from: bareRelativeDownloadURL)
        let bareUnwrapped = try #require(bareResolved)
        #expect(bareUnwrapped.host == "api.cupthread.com")
        #expect(bareUnwrapped.path == "/api/v1/uploads/upl_456/download")
        #expect(bareUnwrapped.query == "token=bare_token")
        #expect(!bareUnwrapped.absoluteString.contains("%3F"))
    }

    @Test func relativeSlotAndDownloadURLPreserveQueryStringDuringUpload() async throws {
        let capturedRequests = CaptureBox<[URLRequest]>()
        MockURLProtocol.setHandler(forHost: host) { [sessionJSON, uploadedJSON] request in
            capturedRequests.value = (capturedRequests.value ?? []) + [request]
            if request.url?.path == "/api/v1/uploads/sessions" {
                return (makeHTTPResponse(status: 201), try encodeJSON(sessionJSON))
            }
            return (makeHTTPResponse(status: 200), try encodeJSON(uploadedJSON))
        }
        defer { MockURLProtocol.setHandler(forHost: host, nil) }

        let client = makeClient(baseURL: URL(string: "https://\(host)")!)
        let attachment = try await client.uploadAttachment(
            data: Data("hello".utf8), filename: "f.png", mimeType: "image/png", userToken: nil
        )

        let requests = try #require(capturedRequests.value)
        #expect(requests.count == 2)
        let putRequest = requests[1]
        #expect(putRequest.httpMethod == "PUT")
        #expect(putRequest.url?.host == host)
        #expect(putRequest.url?.path == "/api/v1/uploads/relative-slot-123")
        #expect(putRequest.url?.query == "sig=test_signature&expires=1700000000")
        #expect(putRequest.url?.absoluteString.contains("%3F") == false)

        #expect(attachment.uploadId == "upl-1")
        #expect(attachment.url.path == "/api/v1/uploads/upl-1/download")
        #expect(attachment.url.query == "token=secret_token")
        #expect(attachment.url.absoluteString.contains("%3F") == false)
    }

    @Test func offOriginAndProtocolRelativeURLsWithQueriesAreRejected() throws {
        let client = makeClient(baseURL: URL(string: "https://api.cupthread.com")!)

        let disallowedSlotURLs = [
            "//evil.example/uploads?sig=123",
            "https://evil.example/uploads?sig=123",
            "javascript:alert(1)?foo=bar"
        ]

        for disallowed in disallowedSlotURLs {
            do {
                _ = try client.uploadURL(from: disallowed)
                Issue.record("Expected \(disallowed) to be rejected by uploadURL")
            } catch let error as FeedbackClientError {
                #expect(error == .invalidResponse)
            } catch {
                Issue.record("Expected FeedbackClientError, got \(error)")
            }
        }

        let disallowedDownloadURLs = [
            "//evil.example/download?token=123",
            "https://evil.example/download?token=123",
            "javascript:alert(1)?token=123"
        ]

        for disallowed in disallowedDownloadURLs {
            #expect(client.resolvedDownloadURL(from: disallowed) == nil)
        }
    }
}
