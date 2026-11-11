import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("UploadSessionApiSync", .serialized)
struct UploadSessionApiSyncTests {
    private let host = "upload-api-sync.example.com"

    private func makeSession(
        sessionID: String,
        uploadIDs: [String]
    ) throws -> FeedbackUploadSession {
        let files = uploadIDs.map { uploadID in
            [
                "clientFileId": "file-\(uploadID)",
                "uploadId": uploadID,
                "uploadUrl": "https://\(host)/api/v1/uploads/\(uploadID)",
                "maxSizeBytes": 20_000_000
            ]
        }
        let json: [String: Any] = [
            "session": [
                "sessionId": sessionID,
                "sessionToken": "{{SECRET_rqhcyhbw}}",
                "expiresAt": "2026-12-31T23:59:59Z",
                "maxFileSizeBytes": 20_000_000,
                "maxFiles": 8
            ],
            "files": files
        ]
        return try JSONDecoder().decode(FeedbackUploadSession.self, from: try encodeJSON(json))
    }

    private func uploadedJSON(uploadID: String) -> [String: Any] {
        [
            "uploadId": uploadID,
            "clientFileId": "file-\(uploadID)",
            "contentType": "image/png",
            "sizeBytes": 4,
            "stored": true
        ]
    }

    @Test func svgInspectionCeilingMatchesScreeningContract() throws {
        #expect(UploadSessionLimits.maxSvgInspectionBytes == 10_000_000)
        let client = makeClient(baseURL: URL(string: "https://\(host)")!)

        #expect(throws: Never.self) {
            try client.validateSvgInspectionSize(size: 10_000_000, contentType: "image/svg+xml", filename: nil)
        }
        #expect(throws: Never.self) {
            try client.validateSvgInspectionSize(size: 10_000_000, contentType: "application/octet-stream", filename: "icon.svg")
        }
        #expect(throws: FeedbackClientError.self) {
            try client.validateSvgInspectionSize(
                size: 10_000_001,
                contentType: "image/svg+xml; charset=utf-8",
                filename: "photo.png"
            )
        }
        #expect(throws: FeedbackClientError.self) {
            try client.validateSvgInspectionSize(
                size: 10_000_001,
                contentType: "application/octet-stream",
                filename: "markup.svg"
            )
        }
        #expect(throws: Never.self) {
            try client.validateSvgInspectionSize(
                size: 10_000_001,
                contentType: "application/octet-stream",
                filename: "photo.png"
            )
        }
    }

    @Test func oversizedSvgIsRejectedBeforeUpload() async throws {
        let putReached = CaptureBox<Bool>()
        MockURLProtocol.setHandler(forHost: host) { _ in
            putReached.value = true
            return (makeHTTPResponse(status: 200), Data())
        }

        let client = makeClient(baseURL: URL(string: "https://\(host)")!)
        let session = try makeSession(sessionID: "sess-svg", uploadIDs: ["upl-svg"])
        let oversizedSVG = Data(count: UploadSessionLimits.maxSvgInspectionBytes + 1)

        do {
            _ = try await client.uploadAttachment(
                data: oversizedSVG,
                contentType: "image/svg+xml",
                session: session
            )
            Issue.record("Expected unsupportedMediaType")
        } catch let error as FeedbackClientError {
            guard case .unsupportedMediaType(let message, _) = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(message?.contains("10000000") == true)
            #expect(putReached.value != true)
        }
    }

    @Test func svgTooLargeResponseSurfacesUnsupportedMediaType() async throws {
        MockURLProtocol.setHandler(forHost: host) { request in
            if request.httpMethod == "POST" {
                return (makeHTTPResponse(status: 201), Data())
            }
            return (
                makeHTTPResponse(status: 415, headers: ["X-Request-Id": "req-svg-ceiling"]),
                try encodeJSON([
                    "error": "SVG exceeds the content-inspection size limit of 10000000 bytes",
                    "code": "svg_too_large"
                ])
            )
        }

        let client = makeClient(baseURL: URL(string: "https://\(host)")!)
        let session = try makeSession(sessionID: "sess-svg-response", uploadIDs: ["upl-svg-response"])

        do {
            _ = try await client.uploadAttachment(
                data: Data("svg".utf8),
                contentType: "image/svg+xml",
                session: session
            )
            Issue.record("Expected unsupportedMediaType")
        } catch let error as FeedbackClientError {
            guard case .unsupportedMediaType(let message, let requestId) = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(message == "SVG exceeds the content-inspection size limit of 10000000 bytes")
            #expect(requestId == "req-svg-ceiling")
        }
    }

    @Test func siblingUploadsAreSerializedPerSession() async throws {
        let requestOrder = CaptureBox<[String]>()
        let releaseFirst = CaptureBox<Bool>()
        MockURLProtocol.setHandler(forHost: host) { request in
            let uploadID = request.url?.lastPathComponent ?? "unknown"
            requestOrder.value = (requestOrder.value ?? []) + [uploadID]
            if uploadID == "upl-a" {
                while releaseFirst.value != true {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            return (
                makeHTTPResponse(status: 200),
                try encodeJSON(self.uploadedJSON(uploadID: uploadID))
            )
        }

        let firstClient = makeClient(baseURL: URL(string: "https://\(host)")!)
        let secondClient = makeClient(baseURL: URL(string: "https://\(host)")!)
        let session = try makeSession(sessionID: "sess-serialized", uploadIDs: ["upl-a", "upl-b"])
        let slots = session.files

        let firstTask = Task {
            try await firstClient.uploadAttachment(
                data: Data("first".utf8),
                contentType: "image/png",
                session: session,
                slot: slots[0]
            )
        }
        while requestOrder.value?.isEmpty != false {
            await Task.yield()
        }

        let secondTask = Task {
            try await secondClient.uploadAttachment(
                data: Data("second".utf8),
                contentType: "image/png",
                session: session,
                slot: slots[1]
            )
        }

        try await Task.sleep(for: .milliseconds(100))
        #expect(requestOrder.value == ["upl-a"])

        releaseFirst.value = true
        let first = try await firstTask.value
        let second = try await secondTask.value

        #expect(first.uploadId == "upl-a")
        #expect(second.uploadId == "upl-b")
        #expect(requestOrder.value == ["upl-a", "upl-b"])
    }

    @Test func queuedSiblingUploadStopsPromptlyWhenCancelled() async throws {
        let requestOrder = CaptureBox<[String]>()
        let releaseFirst = CaptureBox<Bool>()
        MockURLProtocol.setHandler(forHost: host) { request in
            let uploadID = request.url?.lastPathComponent ?? "unknown"
            requestOrder.value = (requestOrder.value ?? []) + [uploadID]
            if uploadID == "upl-a" {
                while releaseFirst.value != true {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            return (
                makeHTTPResponse(status: 200),
                try encodeJSON(self.uploadedJSON(uploadID: uploadID))
            )
        }

        let client = makeClient(baseURL: URL(string: "https://\(host)")!)
        let session = try makeSession(sessionID: "sess-cancelled", uploadIDs: ["upl-a", "upl-b", "upl-c"])
        let slots = session.files

        let firstTask = Task {
            try await client.uploadAttachment(
                data: Data("first".utf8),
                contentType: "image/png",
                session: session,
                slot: slots[0]
            )
        }
        while requestOrder.value?.isEmpty != false {
            await Task.yield()
        }

        let secondTask = Task {
            try await client.uploadAttachment(
                data: Data("second".utf8),
                contentType: "image/png",
                session: session,
                slot: slots[1]
            )
        }

        try await Task.sleep(for: .milliseconds(100))
        secondTask.cancel()
        do {
            _ = try await secondTask.value
            Issue.record("Expected the queued upload task to be cancelled")
        } catch is CancellationError {
            #expect(requestOrder.value == ["upl-a"])
        }

        releaseFirst.value = true
        let first = try await firstTask.value
        #expect(first.uploadId == "upl-a")
        let third = try await client.uploadAttachment(
            data: Data("third".utf8),
            contentType: "image/png",
            session: session,
            slot: slots[2]
        )
        #expect(third.uploadId == "upl-c")
        #expect(requestOrder.value == ["upl-a", "upl-c"])
    }
}
