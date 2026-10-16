import Foundation
import Testing
@testable import CupThreadFeedback

/// Tests for the local 1–8 bounds check on `POST /api/v1/uploads/sessions`
/// (`createUploadSession`, API-28). The endpoint accepts 1–8 `files` per
/// session and can only answer anything else with `400`, so the client must
/// refuse out-of-bounds arrays locally — before a Turnstile token is
/// consumed and before any request is sent.
///
/// The suite uses its own mock host so it cannot stomp (or be stomped by)
/// suites that share the default `test.example.com` handler.
@Suite("UploadSessionBounds", .serialized)
struct UploadSessionBoundsTests {
    private let host = "upload-bounds.example.com"
    private var baseURL: URL { URL(string: "https://\(host)")! }

    /// Thread-safe provider flag recording whether the Turnstile token
    /// provider was ever consulted.
    private final class ProviderBox: @unchecked Sendable {
        private let lock = NSLock()
        private var consulted = false

        func mark() {
            lock.lock()
            defer { lock.unlock() }
            consulted = true
        }

        var wasConsulted: Bool {
            lock.lock()
            defer { lock.unlock() }
            return consulted
        }
    }

    /// Thread-safe counter for intercepted network requests.
    private final class RequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    // MARK: Helpers

    private func makeClient(provider: ProviderBox) -> FeedbackClient {
        FeedbackClient(
            configuration: FeedbackClientConfiguration(
                baseURL: baseURL,
                appKey: "app_uploadbounds"
            ),
            session: makeMockSession(),
            turnstileTokenProvider: { _ in
                provider.mark()
                return "tok-bounds"
            }
        )
    }

    private func spec(_ index: Int) -> FeedbackUploadFileSpec {
        FeedbackUploadFileSpec(
            clientFileId: "file-\(index)",
            filename: "f\(index).png",
            contentType: "image/png",
            sizeBytes: 10
        )
    }

    /// Runs `createUploadSession` against a counting 201 handler and returns
    /// the thrown `FeedbackClientError`, or `nil` when the call succeeded.
    private func thrownError(
        files: [FeedbackUploadFileSpec],
        provider: ProviderBox,
        counter: RequestCounter
    ) async -> FeedbackClientError? {
        MockURLProtocol.setHandler(forHost: host) { _ in
            counter.increment()
            return (makeHTTPResponse(status: 201), Data())
        }
        do {
            _ = try await makeClient(provider: provider).createUploadSession(
                files: files,
                userToken: "tok"
            )
            return nil
        } catch let error as FeedbackClientError {
            return error
        } catch {
            return nil
        }
    }

    private func assertRejectedLocally(
        files: [FeedbackUploadFileSpec]
    ) async throws {
        let provider = ProviderBox()
        let counter = RequestCounter()
        let error = try #require(
            await thrownError(files: files, provider: provider, counter: counter),
            "Expected the out-of-bounds files array to be rejected"
        )
        guard case .invalidResponse = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
        #expect(!provider.wasConsulted, "Turnstile token must not be consumed for an out-of-bounds files array")
        #expect(counter.value == 0, "No request may be sent for an out-of-bounds files array")
    }

    // MARK: Out-of-bounds arrays are refused before any work

    @Test func createUploadSessionRejectsEmptyFilesArrayLocally() async throws {
        try await assertRejectedLocally(files: [])
    }

    @Test func createUploadSessionRejectsOversizedFilesArrayLocally() async throws {
        try await assertRejectedLocally(files: (1...9).map(spec))
    }

    @Test func createUploadSessionRejectsFarOverBoundsFilesArrayLocally() async throws {
        try await assertRejectedLocally(files: (1...32).map(spec))
    }

    // MARK: Boundary counts stay accepted (no off-by-one)

    @Test func createUploadSessionAcceptsSingleFile() async throws {
        try await assertAccepted(fileCount: 1)
    }

    @Test func createUploadSessionAcceptsEightFiles() async throws {
        try await assertAccepted(fileCount: 8)
    }

    /// Installs a counting 201 handler echoing one slot per requested file.
    private func installSessionHandler(counter: RequestCounter) {
        MockURLProtocol.setHandler(forHost: host) { request in
            counter.increment()
            let body = parseJSONDict(bodyData(from: request) ?? Data())
            let files = (body?["files"] as? [[String: Any]]) ?? []
            let slots = files.map { file in
                [
                    "clientFileId": file["clientFileId"] ?? "",
                    "uploadId": "upl-bounds-\(file["clientFileId"] ?? "")",
                    "uploadUrl": "/api/v1/uploads/upl-bounds",
                    "maxSizeBytes": NSNull()
                ] as [String: Any]
            }
            return (
                makeHTTPResponse(status: 201),
                try encodeJSON([
                    "session": [
                        "sessionId": "sess-bounds",
                        "sessionToken": "stok-bounds",
                        "expiresAt": NSNull(),
                        "maxFileSizeBytes": NSNull(),
                        "maxFiles": NSNull()
                    ],
                    "files": slots
                ])
            )
        }
    }

    private func assertAccepted(
        fileCount: Int
    ) async throws {
        let provider = ProviderBox()
        let counter = RequestCounter()
        installSessionHandler(counter: counter)

        let session = try await makeClient(provider: provider).createUploadSession(
            files: (1...fileCount).map(spec),
            userToken: "tok"
        )

        #expect(session.files.count == fileCount)
        #expect(provider.wasConsulted)
        #expect(counter.value == 1)
    }
}
