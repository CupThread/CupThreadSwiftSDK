import Foundation
import Testing
@testable import CupThreadFeedback

/// Tests for the local payload bounds on `POST /api/v1/uploads/sessions`
/// (`createUploadSession`): the 1–8 file-count range (API-28) and the
/// per-file `sizeBytes ≥ 1` floor (issue #611). The endpoint can only answer
/// anything else with `400`, so the client must refuse out-of-bounds payloads
/// locally — before a Turnstile token is consumed and before any request is
/// sent — and must refuse the array as a whole, because the server validates
/// it as one object and a partial session must never be created.
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
        spec(index, sizeBytes: 10)
    }

    private func spec(_ index: Int, sizeBytes: Int) -> FeedbackUploadFileSpec {
        FeedbackUploadFileSpec(
            clientFileId: "file-\(index)",
            filename: "f\(index).png",
            contentType: "image/png",
            sizeBytes: sizeBytes
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

    /// Installs a counting 201 handler echoing one slot per requested file,
    /// optionally capturing the raw session-creation body for wire checks.
    private func installSessionHandler(counter: RequestCounter, body: CaptureBox<Data>? = nil) {
        MockURLProtocol.setHandler(forHost: host) { request in
            counter.increment()
            let rawBody = bodyData(from: request) ?? Data()
            body?.value = rawBody
            let parsed = parseJSONDict(rawBody)
            let files = (parsed?["files"] as? [[String: Any]]) ?? []
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

    // MARK: Per-file size floor (issue #611): sizeBytes < 1 is refused before any work

    @Test func createUploadSessionRejectsZeroByteSpecLocally() async throws {
        try await assertRejectedLocally(files: [spec(1, sizeBytes: 0)])
    }

    @Test func createUploadSessionRejectsNegativeSizeSpecLocally() async throws {
        try await assertRejectedLocally(files: [spec(1, sizeBytes: -1)])
    }

    /// The server validates the payload as one object, so one bad
    /// specification must fail the whole array: a partial session for the
    /// valid entries must never be created, and no Turnstile token may be
    /// spent on the attempt.
    @Test func createUploadSessionRejectsMixedArrayWithOneZeroByteSpecAsAWhole() async throws {
        try await assertRejectedLocally(files: [spec(1), spec(2, sizeBytes: 0), spec(3)])
    }

    // MARK: Size-floor boundary stays accepted (no off-by-one)

    @Test func createUploadSessionAcceptsOneByteSpecAndEncodesItVerbatim() async throws {
        let provider = ProviderBox()
        let counter = RequestCounter()
        let body = CaptureBox<Data>()
        installSessionHandler(counter: counter, body: body)

        let session = try await makeClient(provider: provider).createUploadSession(
            files: [spec(1, sizeBytes: UploadSessionLimits.minFileSizeBytes)],
            userToken: "tok"
        )

        #expect(session.files.count == 1)
        #expect(provider.wasConsulted)
        #expect(counter.value == 1)
        let rawBody = try #require(body.value)
        let payload = try #require(parseJSONDict(rawBody))
        let files = try #require(payload["files"] as? [[String: Any]])
        #expect(files.count == 1)
        #expect(files.first?["sizeBytes"] as? Int == 1)
    }

    // MARK: One-shot helpers refuse an empty payload before a session is created

    /// `uploadAttachment(data:filename:mimeType:)` forwards `data.count` as
    /// the declared size, so empty data would build a `sizeBytes: 0`
    /// specification. It must be refused before the Turnstile provider is
    /// consulted and before the session POST is built.
    @Test func uploadAttachmentDataRejectsEmptyDataBeforeSessionCreation() async throws {
        let provider = ProviderBox()
        let counter = RequestCounter()
        installSessionHandler(counter: counter)

        await #expect(throws: FeedbackClientError.invalidResponse) {
            try await makeClient(provider: provider).uploadAttachment(
                data: Data(),
                filename: "empty.png",
                mimeType: "image/png",
                userToken: "tok"
            )
        }
        #expect(!provider.wasConsulted, "Turnstile token must not be consumed for empty attachment data")
        #expect(counter.value == 0, "No request may be sent for empty attachment data")
    }

    /// `uploadAttachment(fileURL:filename:mimeType:)` forwards the on-disk
    /// size as the declared size, so a genuinely empty file would build a
    /// `sizeBytes: 0` specification. It must be refused before the Turnstile
    /// provider is consulted and before the session POST is built.
    @Test func uploadAttachmentFileURLRejectsEmptyFileBeforeSessionCreation() async throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appending(path: "cupthread-upload-bounds-empty-\(UUID().uuidString).png")
        try Data().write(to: fixtureURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let provider = ProviderBox()
        let counter = RequestCounter()
        installSessionHandler(counter: counter)

        await #expect(throws: FeedbackClientError.invalidResponse) {
            try await makeClient(provider: provider).uploadAttachment(
                fileURL: fixtureURL,
                filename: "empty.png",
                mimeType: "image/png",
                userToken: "tok"
            )
        }
        #expect(!provider.wasConsulted, "Turnstile token must not be consumed for an empty attachment file")
        #expect(counter.value == 0, "No request may be sent for an empty attachment file")
    }
}
