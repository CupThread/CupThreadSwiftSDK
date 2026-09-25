import Foundation
import Testing
@testable import CupThreadFeedback

/// Tests for session-level and slot-level upload size limits (#176).
///
/// Verifies that client-side preflight size checks inspect both `slot.maxSizeBytes`
/// and session-wide `session.maxFileSizeBytes`, enforcing the minimum effective
/// limit and rejecting oversized payloads before any network transport happens.
@Suite("FeedbackUploadSizeLimits", .serialized)
struct FeedbackUploadSizeLimitsTests {
    private let host = "upload-limits.example.com"
    private var baseURL: URL { URL(string: "https://\(host)")! }

    private let uploadedJSON: [String: Any] = [
        "uploadId": "upl-limit-1",
        "clientFileId": "file-1",
        "filename": "f.txt",
        "contentType": "text/plain",
        "sizeBytes": 4,
        "sha256": "abc",
        "stored": true,
        "downloadUrl": "https://example.com/f.txt"
    ]

    private func makeSessionJSON(
        sessionMaxSizeBytes: Int?,
        slotMaxSizeBytes: Int?
    ) -> [String: Any] {
        var sessionDict: [String: Any] = [
            "sessionId": "sess-limit-1",
            "sessionToken": "stok-limit",
            "expiresAt": "2026-09-30T12:00:00Z",
            "maxFiles": 8
        ]
        if let sessionMaxSizeBytes {
            sessionDict["maxFileSizeBytes"] = sessionMaxSizeBytes
        }
        var fileDict: [String: Any] = [
            "clientFileId": "file-1",
            "uploadId": "upl-limit-1",
            "uploadUrl": "https://\(host)/api/v1/uploads/upl-limit-1"
        ]
        if let slotMaxSizeBytes {
            fileDict["maxSizeBytes"] = slotMaxSizeBytes
        }
        return [
            "session": sessionDict,
            "files": [fileDict]
        ]
    }

    private func makeSessionFlowHandler(
        requests: CaptureBox<[URLRequest]>,
        sessionJSON: [String: Any]
    ) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            requests.value = (requests.value ?? []) + [request]
            if request.httpMethod == "POST" {
                return (makeHTTPResponse(status: 201), try encodeJSON(sessionJSON))
            }
            return (makeHTTPResponse(status: 200), try encodeJSON(self.uploadedJSON))
        }
    }

    private func makeTempFixtureFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "cupthread-limits-tests-\(UUID().uuidString).bin")
        try data.write(to: url, options: .atomic)
        return url
    }

    @Test func fileUploadRejectsSessionOversizedFileWithoutTransportWhenSlotLimitOmitted() async throws {
        let bytes = Data(repeating: 0xAB, count: 10)
        let fixtureURL = try makeTempFixtureFile(bytes)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let requests = CaptureBox<[URLRequest]>()
        MockURLProtocol.setHandler(forHost: host, makeSessionFlowHandler(
            requests: requests,
            sessionJSON: makeSessionJSON(sessionMaxSizeBytes: 4, slotMaxSizeBytes: nil)
        ))

        let client = makeClient(baseURL: baseURL)
        do {
            _ = try await client.uploadAttachment(
                fileURL: fixtureURL, filename: "big.bin", mimeType: "application/octet-stream", userToken: "tok"
            )
            Issue.record("Expected payloadTooLarge to be thrown")
        } catch let error as FeedbackClientError {
            guard case .payloadTooLarge = error else {
                Issue.record("Expected .payloadTooLarge, got \(error)")
                return
            }
        }
        // Only the session POST ran; the PUT was suppressed by session limit preflight.
        #expect(requests.value?.count == 1)
    }

    @Test func dataUploadRejectsSessionOversizedDataWithoutTransportWhenSlotLimitOmitted() async throws {
        let bytes = Data(repeating: 0xCD, count: 10)

        let requests = CaptureBox<[URLRequest]>()
        MockURLProtocol.setHandler(forHost: host, makeSessionFlowHandler(
            requests: requests,
            sessionJSON: makeSessionJSON(sessionMaxSizeBytes: 4, slotMaxSizeBytes: nil)
        ))

        let client = makeClient(baseURL: baseURL)
        do {
            _ = try await client.uploadAttachment(
                data: bytes, filename: "data.bin", mimeType: "application/octet-stream", userToken: "tok"
            )
            Issue.record("Expected payloadTooLarge to be thrown")
        } catch let error as FeedbackClientError {
            guard case .payloadTooLarge = error else {
                Issue.record("Expected .payloadTooLarge, got \(error)")
                return
            }
        }
        // Only the session POST ran; the PUT was suppressed by session limit preflight.
        #expect(requests.value?.count == 1)
    }

    @Test func uploadEnforcesMinimumWhenSlotAndSessionLimitsDiffer() async throws {
        let bytes = Data(repeating: 0xEF, count: 6)

        // Case A: slot limit is larger (10), session limit is smaller (4) -> rejected by session limit
        let requestsA = CaptureBox<[URLRequest]>()
        MockURLProtocol.setHandler(forHost: host, makeSessionFlowHandler(
            requests: requestsA,
            sessionJSON: makeSessionJSON(sessionMaxSizeBytes: 4, slotMaxSizeBytes: 10)
        ))

        let clientA = makeClient(baseURL: baseURL)
        do {
            _ = try await clientA.uploadAttachment(
                data: bytes, filename: "data.bin", mimeType: "application/octet-stream", userToken: "tok"
            )
            Issue.record("Expected payloadTooLarge to be thrown")
        } catch let error as FeedbackClientError {
            guard case .payloadTooLarge = error else {
                Issue.record("Expected .payloadTooLarge, got \(error)")
                return
            }
        }
        #expect(requestsA.value?.count == 1)

        // Case B: slot limit is smaller (4), session limit is larger (10) -> rejected by slot limit
        let requestsB = CaptureBox<[URLRequest]>()
        MockURLProtocol.setHandler(forHost: host, makeSessionFlowHandler(
            requests: requestsB,
            sessionJSON: makeSessionJSON(sessionMaxSizeBytes: 10, slotMaxSizeBytes: 4)
        ))

        let clientB = makeClient(baseURL: baseURL)
        do {
            _ = try await clientB.uploadAttachment(
                data: bytes, filename: "data.bin", mimeType: "application/octet-stream", userToken: "tok"
            )
            Issue.record("Expected payloadTooLarge to be thrown")
        } catch let error as FeedbackClientError {
            guard case .payloadTooLarge = error else {
                Issue.record("Expected .payloadTooLarge, got \(error)")
                return
            }
        }
        #expect(requestsB.value?.count == 1)
    }

    @Test func uploadAllowsPayloadWhenUnderBothLimits() async throws {
        let bytes = Data("under".utf8) // 5 bytes

        let requests = CaptureBox<[URLRequest]>()
        MockURLProtocol.setHandler(forHost: host, makeSessionFlowHandler(
            requests: requests,
            sessionJSON: makeSessionJSON(sessionMaxSizeBytes: 20, slotMaxSizeBytes: 10)
        ))

        let client = makeClient(baseURL: baseURL)
        let attachment = try await client.uploadAttachment(
            data: bytes, filename: "ok.txt", mimeType: "text/plain", userToken: "tok"
        )

        #expect(attachment.uploadId == "upl-limit-1")
        #expect(requests.value?.count == 2)
    }

    @Test func effectiveMaxSizeBytesCalculationMatrix() {
        let makeSession = { (sessionLimit: Int?, slotLimit: Int?) -> FeedbackUploadSession in
            FeedbackUploadSession(
                session: FeedbackUploadSession.Info(
                    sessionId: "sess",
                    sessionToken: "tok",
                    expiresAt: nil,
                    maxFileSizeBytes: sessionLimit,
                    maxFiles: 1
                ),
                files: [
                    FeedbackUploadSession.File(
                        clientFileId: "f1",
                        uploadId: "u1",
                        uploadUrl: nil,
                        maxSizeBytes: slotLimit
                    )
                ]
            )
        }

        // Both present: minimum wins
        #expect(makeSession(10, 5).effectiveMaxSizeBytes() == 5)
        #expect(makeSession(5, 10).effectiveMaxSizeBytes() == 5)
        #expect(makeSession(8, 8).effectiveMaxSizeBytes() == 8)

        // Slot only
        #expect(makeSession(nil, 7).effectiveMaxSizeBytes() == 7)

        // Session only
        #expect(makeSession(9, nil).effectiveMaxSizeBytes() == 9)

        // Neither present
        #expect(makeSession(nil, nil).effectiveMaxSizeBytes() == nil)

        // Explicit slot parameter vs default nil
        let session = makeSession(15, 20)
        let explicitSlot = session.files[0]
        #expect(session.effectiveMaxSizeBytes(for: explicitSlot) == 15)
        #expect(session.effectiveMaxSizeBytes(for: nil) == 15)

        // Empty files with nil slot still reflects session limit
        let emptySession = FeedbackUploadSession(
            session: FeedbackUploadSession.Info(
                sessionId: "sess",
                sessionToken: "tok",
                expiresAt: nil,
                maxFileSizeBytes: 12,
                maxFiles: 0
            ),
            files: []
        )
        #expect(emptySession.effectiveMaxSizeBytes() == 12)
    }
}
