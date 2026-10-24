import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Uniform-404 write/read sync (issue #501, SaaS#1171)

/// Pins the uniform-404 existence-hiding convention of SaaS#1171 on the
/// surfaces it changed: the board listing, the roadmap columns/versions
/// fetches, and the Turnstile-gated vote cast. A disabled app answers the
/// same uniform 404 body an unknown `appKey` answers — the SDK must never
/// claim a permission verdict for it, and a denial that no Turnstile token
/// can resolve must never mint one.
@Suite("Uniform404WriteSync", .serialized)
struct Uniform404WriteSyncTests {
    static let host = "uniform-404.example.com"
    static let baseURL = URL(string: "https://\(host)")!

    /// Mirrors `TurnstileRetryTests.makeClient`: the shared `makeClient`
    /// helper has no `turnstileTokenProvider` parameter.
    func makeClient(
        turnstileTokenProvider: (@Sendable (TurnstileChallenge) async -> String?)? = nil
    ) -> FeedbackClient {
        FeedbackClient(
            configuration: FeedbackClientConfiguration(
                baseURL: Self.baseURL,
                appKey: "app_uniform404"
            ),
            session: makeMockSession(),
            turnstileTokenProvider: turnstileTokenProvider
        )
    }

    // MARK: Roadmap columns & versions

    @Test func fetchColumnsMapsDisabledAppUniform404ToUnexpectedStatus() async throws {
        // A disabled app answers the same uniform 404 an unknown appKey
        // answers ("App not found"); the disabled-app case previously
        // answered a documented 403. The envelope falls through to the
        // generic unexpected-status error carrying the server message —
        // existence hiding means the two causes are indistinguishable by
        // contract.
        MockURLProtocol.setHandler(forHost: Self.host) { _ in
            (
                makeHTTPResponse(status: 404, headers: ["X-Request-Id": "req-columns-404"]),
                try encodeJSON(["error": "App not found"])
            )
        }

        do {
            _ = try await makeClient().fetchColumns()
            Issue.record("Expected unexpectedStatus")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, let message, let requestId) = error else {
                Issue.record("Expected unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 404)
            #expect(message == "App not found")
            #expect(requestId == "req-columns-404")
            #expect(error.requestId == "req-columns-404")
            #expect(error.responseBody == "App not found")
        }
    }

    @Test func fetchVersionsMapsDisabledAppUniform404ToUnexpectedStatus() async throws {
        MockURLProtocol.setHandler(forHost: Self.host) { _ in
            (
                makeHTTPResponse(status: 404, headers: ["X-Request-Id": "req-versions-404"]),
                try encodeJSON(["error": "App not found"])
            )
        }

        do {
            _ = try await makeClient().fetchVersions()
            Issue.record("Expected unexpectedStatus")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, let message, let requestId) = error else {
                Issue.record("Expected unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 404)
            #expect(message == "App not found")
            #expect(requestId == "req-versions-404")
            #expect(error.requestId == "req-versions-404")
            #expect(error.responseBody == "App not found")
        }
    }

    // MARK: Board listing

    @Test func fetchFeatureRequestsMapsDisabledAppUniform404ToUnexpectedStatus() async throws {
        MockURLProtocol.setHandler(forHost: Self.host) { _ in
            (
                makeHTTPResponse(status: 404, headers: ["X-Request-Id": "req-listing-404"]),
                try encodeJSON(["error": "App not found"])
            )
        }

        do {
            _ = try await makeClient().fetchFeatureRequests(userToken: "user-listing-1")
            Issue.record("Expected unexpectedStatus")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, let message, let requestId) = error else {
                Issue.record("Expected unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 404)
            #expect(message == "App not found")
            #expect(requestId == "req-listing-404")
            #expect(error.requestId == "req-listing-404")
            #expect(error.responseBody == "App not found")
        }
    }

    // MARK: Vote cast

    @Test func castVoteUniform404DoesNotMintOrRetry() async throws {
        // On the vote cast an unapproved request, a disabled app, and a
        // deactivated app answer the same uniform 404 body a missing id
        // answers ("Feature request not found"), which maps to the typed
        // `.featureRequestNotFound`. The single retry is keyed on the typed
        // `.turnstileRequired` error, so a uniform 404 must surface after
        // exactly one request and exactly one provider consultation (the
        // initial token) — a denial that no token can resolve must never
        // mint one.
        let provider = TokenProvider(["tok-vote-1"])
        let log = RequestLog()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            log.append(request)
            return (
                makeHTTPResponse(status: 404, headers: ["X-Request-Id": "req-vote-404"]),
                try encodeJSON(["error": "Feature request not found"])
            )
        }

        let client = makeClient(turnstileTokenProvider: { _ in await provider.next() })
        do {
            _ = try await client.castVote(featureRequestId: "fr-1", userToken: "user-1")
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .featureRequestNotFound(let message, _) = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(message == "Feature request not found")
            #expect(log.allRequests.count == 1)
            #expect(provider.callCount == 1)
        }
    }
}

// MARK: - Local concurrency-safe stubs

/// Thread-safe provider stub handing out tokens in order and counting every
/// consultation (same shape as `TurnstileRetryTests.TokenProvider`).
private final class TokenProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String?]
    private var calls = 0

    init(_ tokens: [String?]) {
        self.tokens = tokens
    }

    func next() -> String? {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return tokens.isEmpty ? nil : tokens.removeFirst()
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

/// Thread-safe log of every intercepted request (same shape as
/// `TurnstileRetryTests.RequestLog`).
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
    }

    var allRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}
