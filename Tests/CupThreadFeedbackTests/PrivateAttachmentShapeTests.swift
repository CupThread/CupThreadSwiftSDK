import Foundation
import Testing
@testable import CupThreadFeedback

/// Regression tests for the private-attachment upload response (#259):
/// `PUT /api/v1/uploads/{uploadId}` no longer returns `key`, `url`, or
/// `variants`, and reports the new `mimeType`/`size` field names instead of
/// the `contentType`/`sizeBytes` pair the lenient decoder reads. The response
/// must still decode — falling back to slot/local facts for everything the
/// server omits — and the resolved attachment must never carry a public URL,
/// because the stored bytes are only retrievable through the authorized,
/// signed download endpoint after the feedback submission finalizes.
@Suite("FeedbackUploadPrivateAttachmentShape", .serialized)
struct PrivateAttachmentShapeTests {
    /// Distinct host; the mock dispatches handlers per host, so sharing one
    /// with another suite would cross-wire handlers mid-flight.
    private let host = "private-attachment-shape.example.com"
    private var baseURL: URL { URL(string: "https://\(host)")! }

    /// The exact response shape since images became private attachments
    /// (SaaS #604): no `key`, `url`, `variants`, `contentType`, `sizeBytes`,
    /// or `downloadUrl`.
    private var privateAttachmentJSON: [String: Any] {
        [
            "kind": "image",
            "uploadId": "upl-259",
            "status": "uploaded",
            "stored": true,
            "filename": "shot.png",
            "mimeType": "image/png",
            "size": 12_345,
            "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        ]
    }

    private func makeSessionJSON() -> [String: Any] {
        [
            "session": [
                "sessionId": "sess-259",
                "sessionToken": "stok-259",
                "expiresAt": "2026-10-31T12:00:00Z",
                "maxFileSizeBytes": 20_000_000,
                "maxFiles": 8
            ],
            "files": [[
                "clientFileId": "file-1",
                "uploadId": "upl-259",
                "uploadUrl": "https://\(host)/api/v1/uploads/upl-259",
                "maxSizeBytes": 20_000_000
            ]]
        ]
    }

    /// Session-creation + upload-flow handler answering the PUT with the new
    /// private-attachment shape.
    private func makeSessionFlowHandler() -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            if request.httpMethod == "POST" {
                return (makeHTTPResponse(status: 201), try encodeJSON(self.makeSessionJSON()))
            }
            return (makeHTTPResponse(status: 200), try encodeJSON(self.privateAttachmentJSON))
        }
    }

    private func makeTempFixtureFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "cupthread-private-attachment-tests-\(UUID().uuidString).png")
        try data.write(to: url, options: .atomic)
        return url
    }

    @Test func privateAttachmentResponseDecodesWithLocalFactsOverDataPath() async throws {
        MockURLProtocol.setHandler(forHost: host, makeSessionFlowHandler())
        defer { MockURLProtocol.setHandler(forHost: host, nil) }

        let bytes = Data("hello!".utf8)
        let client = makeClient(baseURL: baseURL)
        let attachment = try await client.uploadAttachment(
            data: bytes, filename: "local.png", mimeType: "image/png", userToken: "tok-259"
        )

        // Fields the new response still carries decode from the wire.
        #expect(attachment.uploadId == "upl-259")
        #expect(attachment.filename == "shot.png")
        // Identity mirrors the uploadId — no server storage key exists anymore.
        #expect(attachment.key == "upl-259")
        // `mimeType`/`size` are the new wire names; the lenient decoder does
        // not read them, so the locally declared/known facts stand in.
        #expect(attachment.mimeType == "image/png")
        #expect(attachment.size == bytes.count)
        // Without a `downloadUrl` the slot upload URL remains the display
        // fallback — the SDK never constructs a public `/files/…` URL for a
        // private attachment.
        #expect(attachment.url == baseURL.appending(path: "/api/v1/uploads/upl-259"))
        #expect(attachment.kind == .image)
    }

    @Test func privateAttachmentResponseDecodesWithDiskFactsOverFileURLPath() async throws {
        MockURLProtocol.setHandler(forHost: host, makeSessionFlowHandler())
        defer { MockURLProtocol.setHandler(forHost: host, nil) }

        let bytes = Data("attachment-bytes".utf8)
        let fixtureURL = try makeTempFixtureFile(bytes)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let client = makeClient(baseURL: baseURL)
        let attachment = try await client.uploadAttachment(
            fileURL: fixtureURL, filename: "local.png", mimeType: "image/png", userToken: nil
        )

        #expect(attachment.uploadId == "upl-259")
        #expect(attachment.filename == "shot.png")
        #expect(attachment.mimeType == "image/png")
        // The on-disk size stands in for the unconsumed `size` field.
        #expect(attachment.size == bytes.count)
        #expect(attachment.url == baseURL.appending(path: "/api/v1/uploads/upl-259"))
    }
}
