import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - End-user self-service endpoints

// MARK: - End-user self-service endpoints

@Suite("EndUserClient", .serialized)
struct EndUserClientTests {
    static let apiHost = "apisync-me.example.com"

    @Test func eraseSendsAppKeyBodyWithIdentityHeader() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["erased": true, "endUserId": "enduser-1"]))
        }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
        let result = try await client.eraseMyData(userToken: "tok-1")

        let request = try #require(capture.value)
        #expect(request.url?.path == "/api/v1/me/erase")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-User-Token") == "tok-1")
        let rawBody = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawBody))
        #expect(json["appKey"] as? String == "app_testkey123456")

        #expect(result.erased == true)
        #expect(result.endUserId == "enduser-1")
    }

    @Test func eraseNormalizes404ToNotErased() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 404), try encodeJSON(["erased": false, "error": "No profile found"]))
        }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
        let result = try await client.eraseMyData(userToken: "tok-1")

        #expect(result.erased == false)
        #expect(result.endUserId == nil)
    }

    @Test func eraseMaps429ToRateLimited() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 429), try encodeJSON(["error": "Rate limited"]))
        }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
        do {
            _ = try await client.eraseMyData(userToken: "tok-1")
            Issue.record("Expected error to be thrown")
        } catch FeedbackClientError.rateLimited {
            // expected
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func eraseWithStoreResetsIdentityAfterSuccessfulErasure() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            let token = request.value(forHTTPHeaderField: "X-User-Token")
            return (makeHTTPResponse(), try encodeJSON(["erased": true, "endUserId": token]))
        }

        let isolated = makeIsolatedTokenStore()
        defer { isolated.cleanup() }
        let identity = isolated.store.token

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!, tokenStore: isolated.store)
        let result = try await client.eraseMyData(store: isolated.store)

        #expect(result.erased == true)
        // The server rotated the token; the store must drop it.
        let fresh = isolated.store.token
        #expect(fresh != identity)
        #expect(isolated.defaults.string(forKey: isolated.tokenKey) == fresh)
    }

    @Test func eraseWithStoreKeepsIdentityWhenNothingWasErased() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 404), try encodeJSON(["erased": false, "error": "No profile found"]))
        }

        let isolated = makeIsolatedTokenStore()
        defer { isolated.cleanup() }
        let identity = isolated.store.token

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!, tokenStore: isolated.store)
        let result = try await client.eraseMyData(store: isolated.store)

        #expect(result.erased == false)
        #expect(isolated.store.token == identity)
    }

    @Test func eraseWithStorePropagatesErrorsWithoutResetting() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 429), try encodeJSON(["error": "Rate limited"]))
        }

        let isolated = makeIsolatedTokenStore()
        defer { isolated.cleanup() }
        let identity = isolated.store.token

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!, tokenStore: isolated.store)
        do {
            _ = try await client.eraseMyData(store: isolated.store)
            Issue.record("Expected error to be thrown")
        } catch FeedbackClientError.rateLimited {
            // expected
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(isolated.store.token == identity)
    }

    @Test func linkSendsBearerAndIdentityHeaders() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON([
                "linked": true,
                "endUserId": "enduser-2",
                "clerkUserId": "clerk-1"
            ]))
        }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
        let result = try await client.linkEndUser(sessionToken: "sess-token", userToken: "tok-2")

        let request = try #require(capture.value)
        #expect(request.url?.path == "/api/v1/me/link")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sess-token")
        #expect(request.value(forHTTPHeaderField: "X-User-Token") == "tok-2")

        #expect(result.linked == true)
        #expect(result.endUserId == "enduser-2")
        #expect(result.clerkUserId == "clerk-1")
    }

    @Test func linkSurfaces409ConflictAsUnexpectedStatus() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 409), try encodeJSON([
                "error": "Profile already confirmed to another identity",
                "code": "already_confirmed"
            ]))
        }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
        do {
            _ = try await client.linkEndUser(sessionToken: "sess", userToken: "tok")
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            if case .unexpectedStatus(let code, _, _) = error {
                #expect(code == 409)
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }
}

// MARK: - PUT /user rate-limit retry

@Suite("UserAttributesRateLimit", .serialized)
struct UserAttributesRateLimitTests {
    static let apiHost = "apisync-ratelimit.example.com"

    @Test func updateUserAttributesRetriesOnceAfter429() async throws {
        let requests = CaptureBox<[URLRequest]>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            requests.value = (requests.value ?? []) + [request]
            if (requests.value?.count ?? 0) == 1 {
                return (makeHTTPResponse(status: 429), try encodeJSON(["error": "Rate limit"]))
            }
            return (makeHTTPResponse(), try encodeJSON(["ok": true, "updatedAt": "2026-09-13T00:00:00Z"]))
        }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
        let result = try await client.updateUserAttributes(
            isPaying: true,
            userToken: UUID().uuidString
        )

        #expect(requests.value?.count == 2)
        #expect(result.ok == true)
    }

    @Test func updateUserAttributesThrowsRateLimitedWhenRetryAlsoLimited() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 429), try encodeJSON(["error": "Rate limit"]))
        }

        do {
            let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
            _ = try await client.updateUserAttributes(
                isPaying: true,
                userToken: UUID().uuidString
            )
            Issue.record("Expected error to be thrown")
        } catch FeedbackClientError.rateLimited {
            // expected
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
