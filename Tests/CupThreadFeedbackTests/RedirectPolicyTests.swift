import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Same-origin redirect policy (SEC-11, #284)

/// URLProtocol stub that can answer with plain responses **or** simulated
/// 3xx redirects (`wasRedirectedTo`), driving URLSession's real redirect
/// machinery — including the `willPerformHTTPRedirection` delegate that the
/// SDK's redirect policy is implemented in. Kept separate from
/// `MockURLProtocol` (which only answers final responses) so the shared test
/// support stays untouched.
private final class RedirectStubURLProtocol: URLProtocol, @unchecked Sendable {
    /// What a host handler answers a request with: a final response, or a
    /// redirect to `location` with the given 3xx status.
    enum Outcome {
        case respond(Int, Data)
        case redirect(status: Int, location: URL)
    }

    typealias Handler = (URLRequest) throws -> Outcome

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func setHandler(forHost host: String, _ handler: Handler?) {
        lock.lock()
        defer { lock.unlock() }
        handlers[host] = handler
    }

    private static func handler(forHost host: String) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[host]
    }

    // URLProtocol requires class-func overrides; `static` would not dispatch
    // through the ObjC runtime. swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler(forHost: request.url?.host ?? "") else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            switch try handler(request) {
            case .respond(let status, let data):
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            case .redirect(let status, let location):
                let redirectResponse = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Location": location.absoluteString]
                )!
                // A URLProtocol-simulated redirect cannot exercise a refusal:
                // once `wasRedirectedTo` is signaled, passing `nil` to the
                // delegate's completion handler never completes the stubbed
                // task (it times out) — an artifact of the protocol
                // simulation, not of real networking (a refused redirect
                // against a live server completes immediately with the 3xx).
                // The stub therefore mirrors the shipped policy decision: a
                // same-origin redirect is handed to the session's real
                // redirect machinery, while an off-origin one is delivered
                // as the final 3xx response exactly like real CFNetwork
                // delivers it after the delegate refuses. If the policy
                // ever widened to allow a cross-origin hop, this same code
                // path would signal `wasRedirectedTo` and the trap handler
                // on the target host would record the replayed request, so
                // the end-to-end assertions below still hold.
                if SameOriginRedirectLimiter.isSameOrigin(request.url, redirectURL: location) {
                    client?.urlProtocol(
                        self,
                        wasRedirectedTo: URLRequest(url: location),
                        redirectResponse: redirectResponse
                    )
                } else {
                    client?.urlProtocol(self, didReceive: redirectResponse, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data())
                    client?.urlProtocolDidFinishLoading(self)
                }
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Tests for the same-origin redirect limiter installed on the SDK's default
/// session (#284): a redirect off the original request's origin must be
/// refused — never replaying `Authorization`, `X-User-Token`, or request
/// bodies to the redirect target — and surface as the 3xx response mapped to
/// ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``, while
/// legitimate same-origin redirects keep working end-to-end.
///
/// The suite uses its own stub protocol and hosts so it cannot stomp (or be
/// stomped by) suites sharing `MockURLProtocol` handlers.
@Suite("RedirectPolicy", .serialized)
struct RedirectPolicyTests {
    private let host = "redirect-policy.example.com"
    private let evilHost = "evil-redirect.example.com"
    private let cdnHost = "cdn-redirect.example.com"

    private var baseURL: URL { URL(string: "https://\(host)")! }

    private var sessionJSON: [String: Any] {
        [
            "session": [
                "sessionId": "sess-rp-1",
                "sessionToken": "stok-rp",
                "expiresAt": "2026-09-30T12:00:00Z",
                "maxFileSizeBytes": 20_000_000,
                "maxFiles": 8
            ],
            "files": [[
                "clientFileId": "file-1",
                "uploadId": "upl-rp-1",
                "uploadUrl": "https://\(host)/api/v1/uploads/upl-rp-1",
                "maxSizeBytes": 20_000_000
            ]]
        ]
    }

    private var uploadedJSON: [String: Any] {
        [
            "uploadId": "upl-rp-1",
            "clientFileId": "file-1",
            "filename": "f.txt",
            "contentType": "text/plain",
            "sizeBytes": 4,
            "sha256": "abc",
            "stored": true,
            "downloadUrl": "https://\(host)/f.txt"
        ]
    }

    // MARK: Helpers

    /// A client whose session carries both the redirect-stub protocol **and**
    /// the shipped `SameOriginRedirectLimiter` delegate — the same policy the
    /// default session installs.
    private func makeClient(
        turnstileTokenProvider: (@Sendable () async -> String?)? = nil,
        authenticationProvider: (@Sendable () async -> String?)? = nil
    ) -> FeedbackClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectStubURLProtocol.self]
        let session = URLSession(
            configuration: configuration,
            delegate: SameOriginRedirectLimiter(),
            delegateQueue: nil
        )
        return FeedbackClient(
            configuration: FeedbackClientConfiguration(baseURL: baseURL, appKey: "app_redirectpol"),
            session: session,
            turnstileTokenProvider: turnstileTokenProvider,
            authenticationProvider: authenticationProvider
        )
    }

    /// Records every request reaching a host and answers `200` — the trap
    /// handler proving a refused redirect never reaches its target.
    private func installTrapHandler(forHost trapHost: String) -> CaptureBox<[URLRequest]> {
        let captured = CaptureBox<[URLRequest]>()
        RedirectStubURLProtocol.setHandler(forHost: trapHost) { request in
            captured.value = (captured.value ?? []) + [request]
            return .respond(200, Data())
        }
        return captured
    }

    private func removeHandler(forHost handlerHost: String) {
        RedirectStubURLProtocol.setHandler(forHost: handlerHost, nil)
    }

    private func makeTempFixtureFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "cupthread-redirect-tests-\(UUID().uuidString).bin")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Cross-origin redirects are refused without replaying credentials

    @Test func slotPUTCrossOriginRedirectIsRefusedWithoutReplayingBodyOrBearer() async throws {
        let fixtureURL = try makeTempFixtureFile(Data("attachment-bytes".utf8))
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let evilRequests = installTrapHandler(forHost: evilHost)
        defer { removeHandler(forHost: evilHost) }

        RedirectStubURLProtocol.setHandler(forHost: host) { request in
            if request.httpMethod == "POST" {
                return .respond(201, try encodeJSON(self.sessionJSON))
            }
            return .redirect(
                status: 307,
                location: URL(string: "https://\(self.evilHost)/steal")!
            )
        }
        defer { removeHandler(forHost: host) }

        let client = makeClient()
        do {
            _ = try await client.uploadAttachment(
                fileURL: fixtureURL,
                filename: "leak.bin",
                mimeType: "application/octet-stream",
                userToken: "tok-sec11"
            )
            Issue.record("Expected the cross-origin redirect to be refused")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, _) = error else {
                Issue.record("Expected .unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 307)
        }

        #expect(evilRequests.value == nil || evilRequests.value?.isEmpty == true,
                "The cross-origin redirect target must never receive the upload")
    }

    @Test func linkEndUserCrossOriginRedirectLeaksNoAuthorization() async throws {
        let attackerRequests = installTrapHandler(forHost: evilHost)
        defer { removeHandler(forHost: evilHost) }

        RedirectStubURLProtocol.setHandler(forHost: host) { _ in
            .redirect(
                status: 302,
                location: URL(string: "https://\(self.evilHost)/harvest")!
            )
        }
        defer { removeHandler(forHost: host) }

        let client = makeClient()
        do {
            _ = try await client.linkEndUser(sessionToken: "clerk-session-secret", userToken: "tok-sec11")
            Issue.record("Expected the cross-origin redirect to be refused")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, _) = error else {
                Issue.record("Expected .unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 302)
        }

        #expect(attackerRequests.value == nil || attackerRequests.value?.isEmpty == true,
                "The Clerk session bearer must never reach the redirect target")
    }

    // MARK: Turnstile retry path

    @Test func submitRefusesCrossOriginRedirectOnTurnstileRetryAttempt() async throws {
        let evilRequests = installTrapHandler(forHost: evilHost)
        defer { removeHandler(forHost: evilHost) }

        let apiRequests = CaptureBox<[URLRequest]>()
        RedirectStubURLProtocol.setHandler(forHost: host) { request in
            apiRequests.value = (apiRequests.value ?? []) + [request]
            if apiRequests.value?.count == 1 {
                // First attempt: the server's Turnstile human-verification
                // gate, which normally triggers the single retry.
                return .respond(403, try encodeJSON([
                    "error": "Human verification (Turnstile) is required",
                    "code": "turnstile_required"
                ]))
            }
            // Retried attempt: a cross-origin 307 must be refused, not
            // replayed with the (fresh) body and identity headers.
            return .redirect(
                status: 307,
                location: URL(string: "https://\(self.evilHost)/steal")!
            )
        }
        defer { removeHandler(forHost: host) }

        let client = makeClient(turnstileTokenProvider: { "cf-turnstile-token" })
        do {
            _ = try await client.submit(
                FeedbackDraft(title: "Title", description: "Description", platform: .ios),
                userToken: "tok-sec11"
            )
            Issue.record("Expected the retried cross-origin redirect to be refused")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, _) = error else {
                Issue.record("Expected .unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 307)
        }

        // Both attempts stayed on the API origin; nothing reached the target.
        #expect(apiRequests.value?.count == 2)
        #expect(evilRequests.value == nil || evilRequests.value?.isEmpty == true)
    }

    @Test func submitRefusesCrossOriginRedirectOnFirstAttemptWithoutRetrying() async throws {
        let evilRequests = installTrapHandler(forHost: evilHost)
        defer { removeHandler(forHost: evilHost) }

        let apiRequests = CaptureBox<[URLRequest]>()
        RedirectStubURLProtocol.setHandler(forHost: host) { request in
            apiRequests.value = (apiRequests.value ?? []) + [request]
            return .redirect(
                status: 307,
                location: URL(string: "https://\(self.evilHost)/steal")!
            )
        }
        defer { removeHandler(forHost: host) }

        let client = makeClient(turnstileTokenProvider: { "cf-turnstile-token" })
        do {
            _ = try await client.submit(
                FeedbackDraft(title: "Title", description: "Description", platform: .ios),
                userToken: "tok-sec11"
            )
            Issue.record("Expected the cross-origin redirect to be refused")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, _) = error else {
                Issue.record("Expected .unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 307)
        }

        // A refused redirect is a terminal failure, not a Turnstile
        // rejection: no retry is minted.
        #expect(apiRequests.value?.count == 1)
        #expect(evilRequests.value == nil || evilRequests.value?.isEmpty == true)
    }

    // MARK: Same-origin redirects keep working

    @Test func sameOriginRedirectIsFollowedEndToEnd() async throws {
        let fixtureURL = try makeTempFixtureFile(Data("ok-bytes".utf8))
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        RedirectStubURLProtocol.setHandler(forHost: host) { request in
            if request.httpMethod == "POST" {
                return .respond(201, try encodeJSON(self.sessionJSON))
            }
            if request.url?.path == "/api/v1/uploads/upl-rp-1" {
                // Same-origin redirect (relative target on the API host):
                // legitimate and followed.
                return .redirect(
                    status: 307,
                    location: URL(string: "https://\(self.host)/api/v1/uploads/upl-rp-1/content")!
                )
            }
            return .respond(200, try encodeJSON(self.uploadedJSON))
        }
        defer { removeHandler(forHost: host) }

        let client = makeClient()
        let attachment = try await client.uploadAttachment(
            fileURL: fixtureURL,
            filename: "f.txt",
            mimeType: "text/plain",
            userToken: "tok-sec11"
        )

        #expect(attachment.uploadId == "upl-rp-1")
    }

    // MARK: Multi-hop chains

    @Test func multiHopChainIsRefusedAtTheHopLeavingTheOriginalOrigin() async throws {
        let fixtureURL = try makeTempFixtureFile(Data("multi-hop-bytes".utf8))
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let evilRequests = installTrapHandler(forHost: evilHost)
        defer { removeHandler(forHost: evilHost) }

        RedirectStubURLProtocol.setHandler(forHost: host) { request in
            if request.httpMethod == "POST" {
                return .respond(201, try encodeJSON(self.sessionJSON))
            }
            if request.url?.path == "/api/v1/uploads/upl-rp-1" {
                // Hop 1 stays same-origin and is followed…
                return .redirect(
                    status: 307,
                    location: URL(string: "https://\(self.host)/api/v1/uploads/upl-rp-1/hop")!
                )
            }
            // …but hop 2 leaves the original origin and is refused.
            return .redirect(
                status: 307,
                location: URL(string: "https://\(self.evilHost)/steal")!
            )
        }
        defer { removeHandler(forHost: host) }

        let client = makeClient()
        do {
            _ = try await client.uploadAttachment(
                fileURL: fixtureURL,
                filename: "leak.bin",
                mimeType: "application/octet-stream",
                userToken: "tok-sec11"
            )
            Issue.record("Expected the multi-hop redirect chain to be refused")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, _) = error else {
                Issue.record("Expected .unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 307)
        }

        #expect(evilRequests.value == nil || evilRequests.value?.isEmpty == true,
                "The hop leaving the original origin must be refused")
    }

    @Test func firstCrossOriginHopIsRefusedBeforeAnyLaterHopRuns() async throws {
        let evilRequests = installTrapHandler(forHost: evilHost)
        defer { removeHandler(forHost: evilHost) }
        let cdnRequests = installTrapHandler(forHost: cdnHost)
        defer { removeHandler(forHost: cdnHost) }

        RedirectStubURLProtocol.setHandler(forHost: host) { _ in
            .redirect(
                status: 307,
                location: URL(string: "https://\(self.cdnHost)/hop")!
            )
        }
        defer { removeHandler(forHost: host) }

        RedirectStubURLProtocol.setHandler(forHost: cdnHost) { _ in
            // Would redirect again if this hop were ever reached; it must
            // not be.
            .redirect(
                status: 308,
                location: URL(string: "https://\(self.evilHost)/steal")!
            )
        }
        defer { removeHandler(forHost: cdnHost) }

        let client = makeClient()
        do {
            _ = try await client.linkEndUser(sessionToken: "clerk-session-secret", userToken: "tok-sec11")
            Issue.record("Expected the cross-origin hop to be refused")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, _) = error else {
                Issue.record("Expected .unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 307)
        }

        #expect(cdnRequests.value == nil || cdnRequests.value?.isEmpty == true,
                "The first hop off the original origin must be refused")
        #expect(evilRequests.value == nil || evilRequests.value?.isEmpty == true)
    }

}
