import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - eraseMyData envelope-only 404 contract (BUG-31, #540)

/// `POST /api/v1/me/erase` follows the SDK-wide envelope-only 404 contract:
/// only the API's documented JSON error envelope means "no profile matched
/// the identity" (the idempotent `erased: false` replay). A bare router
/// fallback — text/plain, empty body, JSON without an `error` string, what
/// production answers on deploy skew or a wrong `baseURL` — is an
/// infrastructure failure and surfaces as `.unexpectedStatus`, so a
/// misconfiguration is never misreported as a benign "nothing to erase".
@Suite("DataErasure404Contract", .serialized)
struct DataErasure404ContractTests {
    static let apiHost = "apisync-erase-404.example.com"

    @Test func eraseSurfacesTextPlainRouter404AsUnexpectedStatus() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 404, headers: ["X-Request-Id": "req-erase-router-404"]),
                Data("404 Not Found".utf8)
            )
        }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
        do {
            _ = try await client.eraseMyData(userToken: "tok-1")
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, let message, let requestId) = error else {
                Issue.record("Expected .unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 404)
            #expect(message == "404 Not Found")
            #expect(requestId == "req-erase-router-404")
        }
    }

    @Test func eraseSurfacesEmptyBody404AsUnexpectedStatus() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 404), Data())
        }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
        do {
            _ = try await client.eraseMyData(userToken: "tok-1")
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, _) = error else {
                Issue.record("Expected .unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 404)
        }
    }

    @Test func eraseSurfacesEnvelopelessJSON404AsUnexpectedStatus() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 404), try encodeJSON(["erased": false]))
        }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
        do {
            _ = try await client.eraseMyData(userToken: "tok-1")
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, _) = error else {
                Issue.record("Expected .unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 404)
        }
    }

    @Test func eraseSurfacesBlankEnvelopeErrorMessage404AsUnexpectedStatus() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 404), try encodeJSON(["error": "   "]))
        }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
        do {
            _ = try await client.eraseMyData(userToken: "tok-1")
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, _) = error else {
                Issue.record("Expected .unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 404)
        }
    }

    /// A bare-404 host misconfiguration must not complete the erasure flow:
    /// the error propagates, the store identity survives (no `reset()`), and
    /// no cleanup-pending marker is persisted.
    @Test func eraseWithStorePropagatesBareRouter404WithoutResettingIdentityOrMarker() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 404), Data("404 Not Found".utf8))
        }

        let isolated = makeIsolatedTokenStore()
        defer { isolated.cleanup() }
        let identity = isolated.store.token

        let suiteName = "test.erasurecleanup.bare404.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let cleanupState = DataErasureCleanupState(
            appKey: "app_testkey123456",
            defaults: defaults
        )

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!, tokenStore: isolated.store)
        do {
            _ = try await client.eraseMyData(store: isolated.store, subscriptionStore: nil, cleanupState: cleanupState)
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, _) = error else {
                Issue.record("Expected .unexpectedStatus, got \(error)")
                return
            }
            #expect(code == 404)
        }

        #expect(isolated.store.token == identity)
        // The thrown error happens before any local cleanup; no pending
        // marker is persisted by the bare 404.
        #expect(cleanupState.isPending == false)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
