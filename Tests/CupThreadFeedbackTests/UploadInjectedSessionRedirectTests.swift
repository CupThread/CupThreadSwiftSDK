import Foundation
import Network
import Testing
@testable import CupThreadFeedback

// MARK: - Upload redirect enforcement on injected sessions (#561, SEC-11)

/// A minimal loopback HTTP server driving URLSession's **real** redirect
/// machinery. `RedirectStubURLProtocol`-style URLProtocol simulation cannot
/// exercise a delegate's redirect refusal (a refusal handed back after
/// `wasRedirectedTo` never completes the stubbed task), so these tests bind
/// two listeners on OS-assigned `127.0.0.1` ports — two distinct origins —
/// and let CFNetwork run the whole 3xx flow: an off-origin `Location` is a
/// different port on the loopback interface.
final class LoopbackHTTPServer: @unchecked Sendable {
    struct RequestSummary: Sendable {
        let method: String
        let path: String
        let authorization: String?
    }

    enum StubResponse: Sendable {
        case redirect(status: Int, location: String)
        case json(status: Int, body: String)
    }

    private let queue = DispatchQueue(label: "cupthread.loopback-tests")
    private let listener: NWListener
    private let handler: @Sendable (RequestSummary) -> StubResponse
    private let lock = NSLock()
    private var requests: [RequestSummary] = []

    /// The OS-assigned port; valid after `start()` returned.
    private(set) var port: UInt16 = 0

    init(handler: @escaping @Sendable (RequestSummary) -> StubResponse) throws {
        self.handler = handler
        listener = try NWListener(using: .tcp, on: .any)
    }

    /// Starts accepting and blocks until the listener is ready.
    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        let startError = CaptureBox<Error>()
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.readRequest(connection, buffer: Data())
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                startError.value = error
                ready.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        ready.wait()
        port = listener.port?.rawValue ?? 0
        if let error = startError.value {
            throw error
        }
        guard port > 0 else {
            throw URLError(.badServerResponse)
        }
    }

    func stop() {
        listener.cancel()
    }

    func recordedRequests() -> [RequestSummary] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    // MARK: Request plumbing

    /// Reads until the full request (headers + `Content-Length` body bytes)
    /// has arrived, records it, then answers with the stubbed response. A
    /// truncated request surfaces as a client-side request timeout instead of
    /// a hang.
    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                self.keepReading(connection, buffer: buffer, streamEnded: isComplete || error != nil)
                return
            }
            let parsed = Self.parseHeaders(
                String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
            )
            let bodyBytesReceived = buffer.distance(from: headerEnd.upperBound, to: buffer.endIndex)
            guard bodyBytesReceived >= parsed.contentLength else {
                self.keepReading(connection, buffer: buffer, streamEnded: isComplete || error != nil)
                return
            }
            self.recordAndRespond(connection, summary: parsed.summary)
        }
    }

    /// Continues the receive loop, or cancels a connection whose stream ended
    /// before a complete request arrived.
    private func keepReading(_ connection: NWConnection, buffer: Data, streamEnded: Bool) {
        guard !streamEnded else {
            connection.cancel()
            return
        }
        readRequest(connection, buffer: buffer)
    }

    private static func parseHeaders(_ headers: String) -> (summary: RequestSummary, contentLength: Int) {
        let lines = headers.components(separatedBy: "\r\n")
        let requestLine = (lines.first ?? "").components(separatedBy: " ")
        var authorization: String?
        var contentLength = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard pair.count == 2 else { continue }
            switch pair[0].lowercased() {
            case "authorization": authorization = pair[1]
            case "content-length": contentLength = Int(pair[1]) ?? 0
            default: break
            }
        }
        let method = requestLine.first ?? "?"
        let path = requestLine.count > 1 ? requestLine[1] : "?"
        return (RequestSummary(method: method, path: path, authorization: authorization), contentLength)
    }

    private func recordAndRespond(_ connection: NWConnection, summary: RequestSummary) {
        lock.lock()
        requests.append(summary)
        lock.unlock()

        let response: Data
        switch handler(summary) {
        case .redirect(let status, let location):
            response = Self.httpResponse(
                status: status,
                headers: ["Location": location]
            )
        case .json(let status, let body):
            response = Self.httpResponse(
                status: status,
                headers: ["Content-Type": "application/json"],
                body: Data(body.utf8)
            )
        }
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func httpResponse(
        status: Int,
        headers: [String: String],
        body: Data = Data()
    ) -> Data {
        let reason = status < 400 ? "OK" : "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// The upload PUTs must refuse cross-origin redirects **even when the host
/// injected a plain session with no redirect policy** (#561): before the
/// per-task `SameOriginRedirectLimiter`, Foundation's default redirect policy
/// replayed the PUT — method, headers, and 307/308 body — to whatever host the
/// `Location` named, and a `200` from that host passed response validation as
/// a silent success. The loopback servers make the whole flow real, so the
/// refusal surfaces exactly as documented: the 3xx response itself, mapped to
/// ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``, and the
/// redirect target receives nothing.
@Suite("Upload redirect enforcement on injected sessions")
struct UploadInjectedSessionRedirectTests {
    private static let sessionJSON = """
    {
        "session": {
            "sessionId": "sess-ri-1",
            "sessionToken": "stok-ri",
            "expiresAt": "2027-01-01T00:00:00Z",
            "maxFileSizeBytes": 20000000,
            "maxFiles": 8
        },
        "files": [{
            "clientFileId": "file-1",
            "uploadId": "upl-ri-1",
            "uploadUrl": "/api/v1/uploads/upl-ri-1",
            "maxSizeBytes": 20000000
        }]
    }
    """

    private static let uploadedJSON = """
    {
        "uploadId": "upl-ri-1",
        "filename": "f.txt",
        "contentType": "text/plain",
        "sizeBytes": 4,
        "downloadUrl": "/f.txt"
    }
    """

    // MARK: Helpers

    /// A session with **no** redirect delegate — the documented, supported
    /// injection shape (`FeedbackClient.init(session:)`) whose upload PUTs
    /// leaked under Foundation's default redirect policy before #561.
    private func makePlainSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }

    private func makeClient(session: URLSession, port: UInt16) -> FeedbackClient {
        FeedbackClient(
            configuration: FeedbackClientConfiguration(
                baseURL: URL(string: "http://127.0.0.1:\(port)")!,
                appKey: "app_redirectinjected"
            ),
            session: session
        )
    }

    /// An attacker-origin listener that records everything it receives and
    /// answers `200` with the successful upload JSON.
    private func makeEvilServer() throws -> LoopbackHTTPServer {
        try LoopbackHTTPServer { _ in
            .json(status: 200, body: Self.uploadedJSON)
        }
    }

    /// An API-origin listener: `201` on session creation, a cross-origin
    /// `307` on the upload PUT.
    private func makeAPIServer(port: UInt16) throws -> LoopbackHTTPServer {
        try LoopbackHTTPServer { summary in
            if summary.method == "POST" {
                return .json(status: 201, body: Self.sessionJSON)
            }
            return .redirect(
                status: 307,
                location: "http://127.0.0.1:\(port)/collect"
            )
        }
    }

    private func makeTempFixtureFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "cupthread-injected-redirect-tests-\(UUID().uuidString).bin")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func expectUnexpectedStatus(
        _ statusCode: Int,
        from operation: () async throws -> FeedbackAttachment
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected the cross-origin redirect to be refused")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, _) = error else {
                Issue.record("Expected .unexpectedStatus, got \(error)")
                return
            }
            #expect(code == statusCode)
        } catch {
            Issue.record("Expected FeedbackClientError.unexpectedStatus, got \(error)")
        }
    }

    // MARK: Cross-origin redirects are refused on a plain injected session

    @Test func dataVariantCrossOriginRedirectIsRefusedOnPlainInjectedSession() async throws {
        let evil = try makeEvilServer()
        try evil.start()
        defer { evil.stop() }
        let api = try makeAPIServer(port: evil.port)
        try api.start()
        defer { api.stop() }

        let client = makeClient(session: makePlainSession(), port: api.port)
        await expectUnexpectedStatus(307) {
            try await client.uploadAttachment(
                data: Data("attachment-bytes".utf8),
                filename: "leak.bin",
                mimeType: "application/octet-stream",
                userToken: "tok-561"
            )
        }

        #expect(evil.recordedRequests().isEmpty,
                "The cross-origin redirect target must never receive the upload")
    }

    @Test func fileVariantCrossOriginRedirectIsRefusedOnPlainInjectedSession() async throws {
        let fixtureURL = try makeTempFixtureFile(Data("attachment-bytes".utf8))
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let evil = try makeEvilServer()
        try evil.start()
        defer { evil.stop() }
        let api = try makeAPIServer(port: evil.port)
        try api.start()
        defer { api.stop() }

        let client = makeClient(session: makePlainSession(), port: api.port)
        await expectUnexpectedStatus(307) {
            try await client.uploadAttachment(
                fileURL: fixtureURL,
                filename: "leak.bin",
                mimeType: "application/octet-stream",
                userToken: "tok-561"
            )
        }

        #expect(evil.recordedRequests().isEmpty,
                "The cross-origin redirect target must never receive the upload")
    }

    // MARK: Same-origin redirects keep working on a plain injected session

    @Test func sameOriginRedirectIsStillFollowedOnPlainInjectedSession() async throws {
        let api = try LoopbackHTTPServer { summary in
            switch (summary.method, summary.path) {
            case ("POST", "/api/v1/uploads/sessions"):
                return .json(status: 201, body: Self.sessionJSON)
            case ("PUT", "/api/v1/uploads/upl-ri-1"):
                // Legitimate same-origin redirect: followed.
                return .redirect(status: 307, location: "/api/v1/uploads/upl-ri-1/content")
            default:
                return .json(status: 200, body: Self.uploadedJSON)
            }
        }
        try api.start()
        defer { api.stop() }

        let client = makeClient(session: makePlainSession(), port: api.port)
        let attachment = try await client.uploadAttachment(
            data: Data("ok-bytes".utf8),
            filename: "f.txt",
            mimeType: "text/plain",
            userToken: "tok-561"
        )

        #expect(attachment.uploadId == "upl-ri-1")
        let puts = api.recordedRequests().filter { $0.method == "PUT" }
        #expect(puts.map(\.path) == ["/api/v1/uploads/upl-ri-1", "/api/v1/uploads/upl-ri-1/content"])
        // Only the initial PUT's bearer is pinned: URLSession strips the
        // Authorization header when it rebuilds the redirected request, so
        // the followed hop legitimately arrives without one.
        #expect(puts.first?.authorization == "Bearer stok-ri",
                "The initial upload PUT carries the session bearer to the API origin")
    }

    // MARK: The default session (session-level limiter) still refuses

    @Test func dataVariantCrossOriginRedirectIsRefusedOnDefaultSession() async throws {
        let evil = try makeEvilServer()
        try evil.start()
        defer { evil.stop() }
        let api = try makeAPIServer(port: evil.port)
        try api.start()
        defer { api.stop() }

        // The process-wide default session carries the session-level limiter;
        // the per-task delegate must coexist with it (and match its verdict).
        let client = makeClient(session: FeedbackClient.defaultSession, port: api.port)
        await expectUnexpectedStatus(307) {
            try await client.uploadAttachment(
                data: Data("attachment-bytes".utf8),
                filename: "leak.bin",
                mimeType: "application/octet-stream",
                userToken: "tok-561"
            )
        }

        #expect(evil.recordedRequests().isEmpty)
    }
}
