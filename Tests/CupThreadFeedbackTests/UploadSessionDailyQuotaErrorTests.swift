import Foundation
import Testing
@testable import CupThreadFeedback

/// Tests for daily upload storage quota mapping on `POST /api/v1/uploads/sessions`
/// (`createUploadSession`) and upload convenience methods (API-12, #246).
///
/// When daily upload usage exceeds the workspace cap, the server responds with:
/// `HTTP 429 {"error": "Daily upload storage quota exceeded for this workspace", "code": "daily_storage_quota_exceeded"}`
///
/// The SDK must map this to `.dailyStorageQuotaExceeded(message:requestId:)` with curated
/// user-safe copy rather than `.rateLimited` ("You're doing that too often. Please try again in a minute.").
@Suite("UploadSessionDailyQuotaErrors", .serialized)
struct UploadSessionDailyQuotaErrorTests {
    private let host = "upload-quota.example.com"
    private var baseURL: URL { URL(string: "https://\(host)")! }

    private func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: baseURL)
    }

    private func makeUploadCall(client: FeedbackClient) async throws -> FeedbackUploadSession {
        try await client.createUploadSession(
            files: [FeedbackUploadFileSpec(clientFileId: "f", filename: "f.txt", contentType: "text/plain", sizeBytes: 4)],
            userToken: "tok"
        )
    }

    @Test func createUploadSessionMaps429DailyStorageQuotaExceededToTypedError() async throws {
        MockURLProtocol.setHandler(forHost: host) { _ in
            (
                makeHTTPResponse(status: 429, headers: ["X-Request-Id": "req-daily-quota-123"]),
                try encodeJSON([
                    "error": "Daily upload storage quota exceeded for this workspace",
                    "code": "daily_storage_quota_exceeded"
                ])
            )
        }

        let client = makeAPIClient()
        do {
            _ = try await makeUploadCall(client: client)
            Issue.record("Expected dailyStorageQuotaExceeded to be thrown")
        } catch let error as FeedbackClientError {
            guard case .dailyStorageQuotaExceeded(let message, let requestId) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(message == "Daily upload storage quota exceeded for this workspace")
            #expect(requestId == "req-daily-quota-123")
            #expect(error.requestId == "req-daily-quota-123")
            #expect(error.responseBody == nil)

            let desc = error.errorDescription ?? ""
            #expect(desc.contains("upload limit for today"))
            #expect(desc.contains("req-daily-quota-123"))
            #expect(!desc.contains("too often"))
            #expect(!desc.contains("in a minute"))
            #expect(!desc.contains("Daily upload storage quota exceeded for this workspace"))

            let display = FriendlyError.message(for: error)
            #expect(display == desc)
            #expect(!display.contains("too often"))
            #expect(!display.contains("Daily upload storage quota exceeded for this workspace"))
        }
    }

    @Test func createUploadSessionMapsPlain429ToRateLimited() async throws {
        // Plain 429 without daily_storage_quota_exceeded code must continue mapping to .rateLimited
        MockURLProtocol.setHandler(forHost: host) { _ in
            (
                makeHTTPResponse(status: 429, headers: ["X-Request-Id": "req-rate-limit-456"]),
                try encodeJSON([
                    "error": "Too Many Requests"
                ])
            )
        }

        let client = makeAPIClient()
        do {
            _ = try await makeUploadCall(client: client)
            Issue.record("Expected rateLimited to be thrown")
        } catch let error as FeedbackClientError {
            guard case .rateLimited(let message, let requestId) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(message == "Too Many Requests")
            #expect(requestId == "req-rate-limit-456")
            #expect(error.errorDescription?.contains("too often") == true)
        }
    }

    @Test func convenienceUploadAttachmentPropagatesDailyStorageQuotaExceeded() async throws {
        MockURLProtocol.setHandler(forHost: host) { _ in
            (
                makeHTTPResponse(status: 429, headers: ["X-Request-Id": "req-upload-quota-789"]),
                try encodeJSON([
                    "error": "Daily upload storage quota exceeded for this workspace",
                    "code": "daily_storage_quota_exceeded"
                ])
            )
        }

        let client = makeAPIClient()
        do {
            _ = try await client.uploadAttachment(
                data: Data([1, 2, 3]),
                filename: "shot.png",
                mimeType: "image/png",
                userToken: "tok"
            )
            Issue.record("Expected dailyStorageQuotaExceeded to be thrown")
        } catch let error as FeedbackClientError {
            guard case .dailyStorageQuotaExceeded(let message, let requestId) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(message == "Daily upload storage quota exceeded for this workspace")
            #expect(requestId == "req-upload-quota-789")
        }
    }

    @Test func streamingUploadAttachmentPropagatesDailyStorageQuotaExceeded() async throws {
        MockURLProtocol.setHandler(forHost: host) { _ in
            (
                makeHTTPResponse(status: 429, headers: ["X-Request-Id": "req-stream-quota-999"]),
                try encodeJSON([
                    "error": "Daily upload storage quota exceeded for this workspace",
                    "code": "daily_storage_quota_exceeded"
                ])
            )
        }

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3, 4]).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let client = makeAPIClient()
        do {
            _ = try await client.uploadAttachment(
                fileURL: tempFile,
                filename: "shot.png",
                mimeType: "image/png",
                userToken: "tok"
            )
            Issue.record("Expected dailyStorageQuotaExceeded to be thrown")
        } catch let error as FeedbackClientError {
            guard case .dailyStorageQuotaExceeded(let message, let requestId) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(message == "Daily upload storage quota exceeded for this workspace")
            #expect(requestId == "req-stream-quota-999")
        }
    }

    @Test func convenienceConstructorOmitRequestId() {
        let error = FeedbackClientError.dailyStorageQuotaExceeded(message: "test")
        #expect(error.requestId == nil)
        #expect(error.responseBody == nil)
        #expect(error.errorDescription == "This app has reached its upload limit for today. Please try again later.")
        #expect(error == .dailyStorageQuotaExceeded(message: "test", requestId: nil))
        #expect(error != .dailyStorageQuotaExceeded(message: "test", requestId: "req-1"))
    }
}
