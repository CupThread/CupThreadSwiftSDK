import Foundation
import Testing
@testable import CupThreadFeedback

/// Tests for the file-backed upload path (`uploadAttachment(fileURL:...)`),
/// which streams attachment bytes off disk via `upload(for:fromFile:)`
/// instead of buffering the whole body in memory (#43).
///
/// The suite uses its own mock host so it cannot stomp (or be stomped by)
/// suites that share the default `test.example.com` handler.
@Suite("FeedbackUploadStreaming", .serialized)
struct FeedbackUploadStreamingTests {
    /// Distinct host; both the client base URL and the slot's absolute
    /// `uploadUrl` must use it, since the mock dispatches handlers per host.
    private let host = "upload-stream.example.com"
    private var baseURL: URL { URL(string: "https://\(host)")! }

    private func makeSessionJSON(maxSizeBytes: Int = 20_000_000) -> [String: Any] {
        [
            "session": [
                "sessionId": "sess-stream-1",
                "sessionToken": "stok-stream",
                "expiresAt": "2026-09-30T12:00:00Z",
                "maxFileSizeBytes": maxSizeBytes,
                "maxFiles": 8
            ],
            "files": [[
                "clientFileId": "file-1",
                "uploadId": "upl-stream-1",
                "uploadUrl": "https://\(host)/api/v1/uploads/upl-stream-1",
                "maxSizeBytes": maxSizeBytes
            ]]
        ]
    }

    private let uploadedJSON: [String: Any] = [
        "uploadId": "upl-stream-1",
        "clientFileId": "file-1",
        "filename": "f.txt",
        "contentType": "text/plain",
        "sizeBytes": 4,
        "sha256": "abc",
        "stored": true,
        "downloadUrl": "https://example.com/f.txt"
    ]

    /// Session-creation + upload-flow handler capturing every request in
    /// order, plus the PUT body bytes as received by the URLProtocol.
    private func makeSessionFlowHandler(
        requests: CaptureBox<[URLRequest]>,
        putBody: CaptureBox<Data>? = nil,
        sessionJSON: [String: Any],
        sessionStatus: Int = 201,
        putStatus: Int = 200
    ) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            requests.value = (requests.value ?? []) + [request]
            if request.httpMethod == "POST" {
                return (makeHTTPResponse(status: sessionStatus), try encodeJSON(sessionJSON))
            }
            putBody?.value = bodyData(from: request)
            return (makeHTTPResponse(status: putStatus), try encodeJSON(self.uploadedJSON))
        }
    }

    private func makeTempFixtureFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "cupthread-streaming-tests-\(UUID().uuidString).bin")
        try data.write(to: url, options: .atomic)
        return url
    }

    @Test func fileUploadProducesSameWireFormatAsDataUpload() async throws {
        let bytes = Data("stream me".utf8)

        // Data-based variant (reference).
        let dataRequests = CaptureBox<[URLRequest]>()
        let dataBody = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: host, makeSessionFlowHandler(
            requests: dataRequests, putBody: dataBody, sessionJSON: makeSessionJSON()
        ))
        let dataClient = makeClient(baseURL: baseURL)
        let dataAttachment = try await dataClient.uploadAttachment(
            data: bytes, filename: "f.txt", mimeType: "text/plain", userToken: "tok-1"
        )

        // File-based variant.
        let fixtureURL = try makeTempFixtureFile(bytes)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        let fileRequests = CaptureBox<[URLRequest]>()
        let fileBody = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: host, makeSessionFlowHandler(
            requests: fileRequests, putBody: fileBody, sessionJSON: makeSessionJSON()
        ))
        let fileClient = makeClient(baseURL: baseURL)
        let fileAttachment = try await fileClient.uploadAttachment(
            fileURL: fixtureURL, filename: "f.txt", mimeType: "text/plain", userToken: "tok-1"
        )

        let dataPut = try #require(dataRequests.value?[safe: 1])
        let filePut = try #require(fileRequests.value?[safe: 1])
        #expect(filePut.httpMethod == "PUT")
        #expect(filePut.url?.path == dataPut.url?.path)
        #expect(filePut.value(forHTTPHeaderField: "Authorization") == dataPut.value(forHTTPHeaderField: "Authorization"))
        #expect(filePut.value(forHTTPHeaderField: "Content-Type") == dataPut.value(forHTTPHeaderField: "Content-Type"))
        #expect(filePut.value(forHTTPHeaderField: "X-Request-Id")?.isEmpty == false)
        #expect(filePut.value(forHTTPHeaderField: "X-SDK-Version") == dataPut.value(forHTTPHeaderField: "X-SDK-Version"))
        #expect(fileBody.value == bytes)
        #expect(fileBody.value == dataBody.value)

        #expect(fileAttachment == dataAttachment)
    }

    @Test func endToEndFileUploadDeclaresFileSizeAndStreamsBytes() async throws {
        // Odd size well past the 4 KB stream-reading buffer used by the
        // test helper, so a truncated body read cannot pass the byte check.
        let bytes = Data((0..<100_003).map { UInt8(truncatingIfNeeded: $0 &+ 7) })
        let fixtureURL = try makeTempFixtureFile(bytes)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let requests = CaptureBox<[URLRequest]>()
        let putBody = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: host, makeSessionFlowHandler(
            requests: requests, putBody: putBody, sessionJSON: makeSessionJSON()
        ))

        let client = makeClient(baseURL: baseURL)
        let attachment = try await client.uploadAttachment(
            fileURL: fixtureURL, filename: "big.bin", mimeType: "application/octet-stream", userToken: "tok-2"
        )

        let captured = try #require(requests.value)
        #expect(captured.count == 2)

        let sessionBodyData = try #require(bodyData(from: captured[0]))
        let sessionBody = try #require(parseJSONDict(sessionBodyData))
        let files = try #require(sessionBody["files"] as? [[String: Any]])
        #expect(files.first?["sizeBytes"] as? Int == bytes.count)
        #expect(files.first?["contentType"] as? String == "application/octet-stream")
        #expect(files.first?["clientFileId"] as? String == "file-1")
        #expect(captured[0].value(forHTTPHeaderField: "X-User-Token") == "tok-2")

        #expect(putBody.value == bytes)

        #expect(attachment.uploadId == "upl-stream-1")
        #expect(attachment.key == "upl-stream-1")
        #expect(attachment.size == 4)
        #expect(attachment.url == URL(string: "https://example.com/f.txt"))
    }

    @Test func fileUploadRejectsOversizedFileWithoutTransport() async throws {
        let bytes = Data(repeating: 0xAB, count: 10)
        let fixtureURL = try makeTempFixtureFile(bytes)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let requests = CaptureBox<[URLRequest]>()
        MockURLProtocol.setHandler(forHost: host, makeSessionFlowHandler(
            requests: requests, sessionJSON: makeSessionJSON(maxSizeBytes: 4)
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
        // Only the session POST ran; the PUT never left the client.
        #expect(requests.value?.count == 1)
    }

    @Test func fileUploadMapsPutRejectionToTypedError() async throws {
        let fixtureURL = try makeTempFixtureFile(Data("mismatch".utf8))
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let requests = CaptureBox<[URLRequest]>()
        MockURLProtocol.setHandler(forHost: host, makeSessionFlowHandler(
            requests: requests,
            sessionJSON: makeSessionJSON(),
            putStatus: 415
        ))

        let client = makeClient(baseURL: baseURL)
        do {
            _ = try await client.uploadAttachment(
                fileURL: fixtureURL, filename: "f.txt", mimeType: "text/plain", userToken: "tok"
            )
            Issue.record("Expected unsupportedMediaType to be thrown")
        } catch let error as FeedbackClientError {
            guard case .unsupportedMediaType = error else {
                Issue.record("Expected .unsupportedMediaType, got \(error)")
                return
            }
        }
    }

    @Test func fileUploadFailsWhenFixtureIsMissing() async throws {
        let requests = CaptureBox<[URLRequest]>()
        MockURLProtocol.setHandler(forHost: host, makeSessionFlowHandler(
            requests: requests, sessionJSON: makeSessionJSON()
        ))

        let missingURL = FileManager.default.temporaryDirectory
            .appending(path: "cupthread-streaming-tests-missing-\(UUID().uuidString).bin")

        let client = makeClient(baseURL: baseURL)
        do {
            _ = try await client.uploadAttachment(
                fileURL: missingURL, filename: "f.txt", mimeType: "text/plain", userToken: "tok"
            )
            Issue.record("Expected the missing fixture to throw")
        } catch {
            // Any error is fine here; FileManager's read failure surfaces
            // before any network traffic happens.
        }
        // The missing size aborts before the session is even created.
        #expect(requests.value == nil)
    }

    @Test func spooledTempUploadFileRoundTripsBytesAndCleansUp() async throws {
        let bytes = Data("spool me".utf8)
        let id = UUID()

        let url = try await PhotoAttachmentHelper.makeTempUploadFile(
            bytes, fileExtension: "jpg", id: id
        )
        #expect(url.lastPathComponent == "cupthread-upload-\(id.uuidString.lowercased()).jpg")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: url) == bytes)

        PhotoAttachmentHelper.removeTempUploadFile(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // Removing again is a tolerated no-op.
        PhotoAttachmentHelper.removeTempUploadFile(at: url)
    }

    @Test func spooledTempUploadFilesAreUniquePerUploadId() async throws {
        let bytes = Data(repeating: 1, count: 16)
        let firstID = UUID()
        let secondID = UUID()

        let firstURL = try await PhotoAttachmentHelper.makeTempUploadFile(
            bytes, fileExtension: "png", id: firstID
        )
        let secondURL = try await PhotoAttachmentHelper.makeTempUploadFile(
            bytes, fileExtension: "png", id: secondID
        )
        defer {
            PhotoAttachmentHelper.removeTempUploadFile(at: firstURL)
            PhotoAttachmentHelper.removeTempUploadFile(at: secondURL)
        }

        #expect(firstURL != secondURL)
        #expect(try Data(contentsOf: firstURL) == bytes)
        #expect(try Data(contentsOf: secondURL) == bytes)
    }

    @Test func streamingFileUploadRejectsOffOriginSlotUploadURLBeforeStreaming() async throws {
        let evilHost = "evil.example"
        let evilRequests = CaptureBox<[URLRequest]>()
        MockURLProtocol.setHandler(forHost: evilHost) { request in
            evilRequests.value = (evilRequests.value ?? []) + [request]
            return (makeHTTPResponse(status: 200), Data())
        }
        defer { MockURLProtocol.setHandler(forHost: evilHost, nil) }

        var maliciousSession = makeSessionJSON()
        maliciousSession["files"] = [[
            "clientFileId": "file-1",
            "uploadId": "upl-stream-1",
            "uploadUrl": "https://evil.example/stream-collect",
            "maxSizeBytes": 20_000_000
        ]]

        let fixtureURL = try makeTempFixtureFile(Data("sensitive-stream".utf8))
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let requests = CaptureBox<[URLRequest]>()
        MockURLProtocol.setHandler(forHost: host, makeSessionFlowHandler(
            requests: requests, sessionJSON: maliciousSession
        ))

        let client = makeClient(baseURL: baseURL)
        do {
            _ = try await client.uploadAttachment(
                fileURL: fixtureURL, filename: "leak.bin", mimeType: "application/octet-stream", userToken: "tok"
            )
            Issue.record("Expected off-origin slot uploadUrl to throw invalidResponse")
        } catch let error as FeedbackClientError {
            #expect(error == .invalidResponse)
        }

        #expect(evilRequests.value == nil || evilRequests.value?.isEmpty == true,
                "Zero streaming requests must reach the foreign host")
    }

    @Test func streamingFileUploadWithRelativeSlotUrlPUTsToConfiguredBaseURL() async throws {
        var relativeSession = makeSessionJSON()
        relativeSession["files"] = [[
            "clientFileId": "file-1",
            "uploadId": "upl-stream-1",
            "uploadUrl": "/api/v1/uploads/stream-custom-rel",
            "maxSizeBytes": 20_000_000
        ]]

        let fixtureURL = try makeTempFixtureFile(Data("stream bytes".utf8))
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let requests = CaptureBox<[URLRequest]>()
        MockURLProtocol.setHandler(forHost: host, makeSessionFlowHandler(
            requests: requests, sessionJSON: relativeSession
        ))

        let client = makeClient(baseURL: baseURL)
        let attachment = try await client.uploadAttachment(
            fileURL: fixtureURL, filename: "stream.bin", mimeType: "application/octet-stream", userToken: "tok"
        )

        let captured = try #require(requests.value)
        #expect(captured.count == 2)
        let putRequest = captured[1]
        #expect(putRequest.httpMethod == "PUT")
        #expect(putRequest.url?.host == host)
        #expect(putRequest.url?.path == "/api/v1/uploads/stream-custom-rel")
        #expect(attachment.uploadId == "upl-stream-1")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
