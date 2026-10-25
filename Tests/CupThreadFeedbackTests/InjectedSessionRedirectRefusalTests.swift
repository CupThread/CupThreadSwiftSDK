import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - JSON endpoint redirect enforcement on injected sessions (#571, SEC-11)

/// Every JSON dispatch — the shared `sendJSON`/Turnstile plumbing and the
/// hand-rolled call sites alike — must refuse cross-origin redirects on
/// **any** session, not only the upload PUTs (#561): each
/// `session.data(for:)` call installs the per-task
/// `SameOriginRedirectLimiter`, so a plain injected session (the documented
/// `FeedbackClient.init(session:)` shape with no redirect policy of its own)
/// surfaces a cross-origin 3xx as the final response
/// (``FeedbackClientError/unexpectedStatus(code:message:requestId:)``) and
/// the `Location` host never receives the replayed `Authorization: Bearer …`,
/// `X-User-Token`, or request body. The same real-redirect loopback harness
/// as `UploadInjectedSessionRedirectTests` is used, because URLProtocol
/// stubbing cannot exercise a delegate's redirect refusal.
@Suite("JSON endpoint redirect enforcement on injected sessions")
struct InjectedSessionRedirectRefusalTests {
    private static let changelogPageJSON = """
    {
        "entries": [{
            "id": "entry-571",
            "title": "Redirect hardening",
            "body": "Body",
            "versionLabel": "1.0.0",
            "publishedAt": "2026-10-25T00:00:00Z",
            "linkedRequests": []
        }],
        "hasMore": false
    }
    """

    // MARK: Helpers

    /// A session with **no** redirect delegate — the documented, supported
    /// injection shape whose JSON requests leaked under Foundation's default
    /// redirect policy before #571.
    private func makePlainSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }

    private func makeClient(
        session: URLSession,
        port: UInt16,
        authenticationProvider: (@Sendable () async -> String?)? = { "bearer-571" }
    ) -> FeedbackClient {
        FeedbackClient(
            configuration: FeedbackClientConfiguration(
                baseURL: URL(string: "http://127.0.0.1:\(port)")!,
                appKey: "app_redirectinjected"
            ),
            session: session,
            authenticationProvider: authenticationProvider
        )
    }

    /// An attacker-origin listener that records everything it receives and
    /// answers `200` with a decodable body.
    private func makeEvilServer() throws -> LoopbackHTTPServer {
        try LoopbackHTTPServer { _ in
            .json(status: 200, body: Self.changelogPageJSON)
        }
    }

    /// An API-origin listener that answers every request with a cross-origin
    /// `307` pointing at `evilPort`.
    private func makeCrossOriginAPIServer(port evilPort: UInt16) throws -> LoopbackHTTPServer {
        try LoopbackHTTPServer { _ in
            .redirect(status: 307, location: "http://127.0.0.1:\(evilPort)/collect")
        }
    }

    private func expectUnexpectedStatus(
        _ statusCode: Int,
        from operation: () async throws -> Void
    ) async {
        do {
            try await operation()
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

    @Test func sendJSONCrossOriginRedirectIsRefusedOnPlainInjectedSession() async throws {
        let evil = try makeEvilServer()
        try evil.start()
        defer { evil.stop() }
        let api = try makeCrossOriginAPIServer(port: evil.port)
        try api.start()
        defer { api.stop() }

        let client = makeClient(session: makePlainSession(), port: api.port)
        await expectUnexpectedStatus(307) {
            // `subscribeToChangelog` is a `sendJSON` call carrying the
            // end-user bearer, the `X-User-Token` identity, and the
            // subscriber's email address in the body.
            try await client.subscribeToChangelog(
                email: "subscriber@example.com",
                userToken: "tok-571"
            )
        }

        #expect(evil.recordedRequests().isEmpty,
                "The cross-origin redirect target must never receive the replayed request")
    }

    @Test func changelogFetchCrossOriginRedirectIsRefusedOnPlainInjectedSession() async throws {
        let evil = try makeEvilServer()
        try evil.start()
        defer { evil.stop() }
        let api = try makeCrossOriginAPIServer(port: evil.port)
        try api.start()
        defer { api.stop() }

        let client = makeClient(session: makePlainSession(), port: api.port)
        await expectUnexpectedStatus(307) {
            // The hand-rolled changelog feed GET carries the bearer when an
            // authentication provider is installed.
            try await client.fetchChangelog(limit: 1)
        }

        #expect(evil.recordedRequests().isEmpty)
    }

    // MARK: Same-origin redirects keep working on a plain injected session

    @Test func changelogFetchSameOriginRedirectIsStillFollowedOnPlainInjectedSession() async throws {
        let api = try LoopbackHTTPServer { summary in
            if summary.path.hasSuffix("/changelog/early-access") {
                return .json(status: 200, body: Self.changelogPageJSON)
            }
            // Legitimate same-origin redirect: followed.
            return .redirect(status: 307, location: "/api/v1/public/apps/app_redirectinjected/changelog/early-access")
        }
        try api.start()
        defer { api.stop() }

        let client = makeClient(session: makePlainSession(), port: api.port)
        let page = try await client.fetchChangelog(limit: 1)

        #expect(page.entries.map(\.id) == ["entry-571"])
        #expect(page.hasMore == false)
        let gets = api.recordedRequests().filter { $0.method == "GET" }
        #expect(gets.count == 2)
        #expect(gets.first?.path.hasSuffix("/changelog?limit=1") == true)
        #expect(gets.last?.path.hasSuffix("/changelog/early-access") == true)
    }

    // MARK: The default session (session-level limiter) still refuses

    @Test func changelogFetchCrossOriginRedirectIsRefusedOnDefaultSession() async throws {
        let evil = try makeEvilServer()
        try evil.start()
        defer { evil.stop() }
        let api = try makeCrossOriginAPIServer(port: evil.port)
        try api.start()
        defer { api.stop() }

        // The process-wide default session carries the session-level limiter;
        // the per-task delegate must coexist with it (and match its verdict).
        let client = makeClient(session: FeedbackClient.defaultSession, port: api.port)
        await expectUnexpectedStatus(307) {
            try await client.fetchChangelog(limit: 1)
        }

        #expect(evil.recordedRequests().isEmpty)
    }
}
