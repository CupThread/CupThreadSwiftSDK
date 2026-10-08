import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Download-URL host policy over the real upload path (SEC-8)

/// End-to-end contract over the real upload flow: a hostile or buggy upload PUT
/// response must never plant an off-origin `downloadUrl` on
/// ``FeedbackAttachment/url``, while legitimate same-registrable CDN hosts keep
/// working. The host-level unit matrix lives in ``DownloadHostValidationTests``.
@Suite("FeedbackUploadDownloadHostPolicy", .serialized)
struct FeedbackUploadDownloadHostTests {
    // Distinct from other suites' mock hosts: suites register per-host
    // MockURLProtocol handlers and run in parallel, so sharing a host would
    // cross-wire their handlers mid-flight.
    private let host = "download-host-policy.example.com"

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
            "uploadUrl": "https://download-host-policy.example.com/api/v1/uploads/upl-1",
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
        "downloadUrl": "https://example.com/f.png"
    ]

    @Test func sameRegistrableCDNDownloadURLPropagatesToAttachmentURL() async throws {
        // A CDN host on the same registrable domain as the API base is a
        // legitimate download target and must survive host validation (SEC-8).
        var cdnUploadedJSON = uploadedJSON
        cdnUploadedJSON["downloadUrl"] = "https://cdn.example.com/uploaded.png"

        MockURLProtocol.setHandler(forHost: host) { [sessionJSON, cdnUploadedJSON] request in
            if request.url?.path == "/api/v1/uploads/sessions" {
                return (makeHTTPResponse(status: 201), try encodeJSON(sessionJSON))
            }
            return (makeHTTPResponse(status: 200), try encodeJSON(cdnUploadedJSON))
        }
        defer { MockURLProtocol.setHandler(forHost: host, nil) }

        let client = makeClient(baseURL: URL(string: "https://\(host)")!)
        let attachment = try await client.uploadAttachment(
            data: Data("hello".utf8), filename: "f.png", mimeType: "image/png", userToken: nil
        )

        #expect(attachment.url == URL(string: "https://cdn.example.com/uploaded.png"))
    }

    @Test func publicSuffixSiblingDownloadURLDoesNotPropagateToAttachmentURL() async throws {
        // `attacker.co.uk` and `api.example.co.uk` share only the `co.uk`
        // public suffix — the legacy suffix(2) "root" comparison accepted it,
        // so a hostile PUT response could plant an off-origin URL (SEC-8).
        let coUKHost = "api.example.co.uk"
        var siblingSessionJSON = sessionJSON
        siblingSessionJSON["files"] = [[
            "clientFileId": "file-1",
            "uploadId": "upl-1",
            "uploadUrl": "https://\(coUKHost)/api/v1/uploads/upl-1",
            "maxSizeBytes": 20_000_000
        ]]
        var siblingUploadedJSON = uploadedJSON
        siblingUploadedJSON["downloadUrl"] = "https://attacker.co.uk/uploaded.png"

        MockURLProtocol.setHandler(forHost: coUKHost) { [siblingSessionJSON, siblingUploadedJSON] request in
            if request.url?.path == "/api/v1/uploads/sessions" {
                return (makeHTTPResponse(status: 201), try encodeJSON(siblingSessionJSON))
            }
            return (makeHTTPResponse(status: 200), try encodeJSON(siblingUploadedJSON))
        }
        defer { MockURLProtocol.setHandler(forHost: coUKHost, nil) }

        let client = makeClient(baseURL: URL(string: "https://\(coUKHost)")!)
        let attachment = try await client.uploadAttachment(
            data: Data("hello".utf8), filename: "f.png", mimeType: "image/png", userToken: nil
        )

        #expect(attachment.url != URL(string: "https://attacker.co.uk/uploaded.png"))
        #expect(attachment.url.host == coUKHost)
    }
}
