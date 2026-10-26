import Foundation
import Testing
@testable import CupThreadFeedback

// Issue #617: the live contract types the end-user identity as
// `format: uuid` on `POST /api/v1/feature-requests` (body `requesterToken`
// and `X-User-Token`), `POST`/`DELETE /api/v1/feature-requests/{id}/vote`,
// and `POST /api/v1/uploads/sessions` (`X-User-Token`) — while
// `POST /api/v1/feedback`'s header is a plain string. A host-supplied
// non-UUID token used to burn a single-use Turnstile challenge on every
// uuid-typed write and earn a deterministic generic `400`; the SDK now
// rejects it locally with the typed `.invalidIdentityToken`, layered after
// the unchanged #493 blank/newline gate.

/// Grammar-level boundary tests for `UserIdentityGrammar`.
@Suite("UserIdentityGrammar")
struct UserIdentityGrammarTests {
    private static let lowercase = "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f"
    private static let uppercase = "3F2C9A1E-7B4D-4C8A-9E2F-1A2B3C4D5E6F"

    @Test("canonical hyphenated UUIDs pass in either letter case")
    func canonicalUUIDsPass() {
        #expect(UserIdentityGrammar.isValid(Self.lowercase))
        #expect(UserIdentityGrammar.isValid(Self.uppercase))
        #expect(UserIdentityGrammar.isValid(UUID().uuidString.lowercased()))
        #expect(UserIdentityGrammar.isValid(UUID().uuidString))
    }

    @Test("values the wire's uuid format rejects fail the grammar")
    func nonUUIDValuesFail() {
        let invalid = [
            "",
            "user_12345",
            "not-a-uuid",
            "tok-1",
            "3f2c9a1e7b4d4c8a9e2f1a2b3c4d5e6f",                 // 32 hex, no dashes
            "{3F2C9A1E-7B4D-4C8A-9E2F-1A2B3C4D5E6F}",           // braced — UUID(uuidString:) accepts, the wire does not
            "urn:uuid:3F2C9A1E-7B4D-4C8A-9E2F-1A2B3C4D5E6F",    // urn form
            "3f2c9a1e_7b4d-4c8a-9e2f-1a2b3c4d5e6f",             // underscore where a dash belongs
            "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6",              // 35 chars
            "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6ff",            // 37 chars
            "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6g",             // non-hex digit
            "3f2c9a1é-7b4d-4c8a-9e2f-1a2b3c4d5e6f",             // non-ASCII
            "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f ",            // trailing space (untrimmed input)
            "3f2c9a1e 7b4d-4c8a-9e2f-1a2b3c4d5e6f",             // space where a dash belongs
            "é\u{0301}2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f-xxxx"  // multi-scalar grapheme
        ]
        for value in invalid {
            #expect(!UserIdentityGrammar.isValid(value), "expected reject: \(value)")
        }
    }

    @Test("a UserTokenStore-minted token always passes the grammar")
    func storeMintedTokenPasses() {
        // The fallback invariant (issue #617): `resolvedIdentity` falls back
        // to the store, and the store only mints lowercase UUIDs (#511) — so
        // the nil-token path can never trip the new gate.
        let store = UserTokenStore(appKey: "app_identitygate_storecheck")
        #expect(UserIdentityGrammar.isValid(store.token))
    }
}

/// Client-level gate tests: every uuid-typed entry point rejects a non-UUID
/// identity locally — before the Turnstile provider is consulted and before
/// any request is sent — while the plain-string feedback path keeps
/// dispatching and the #493 blank/newline semantics are unchanged.
@Suite("UserIdentityGate", .serialized)
struct UserIdentityGateTests {
    private let host = "identity-gate.example.com"
    private var baseURL: URL { URL(string: "https://\(host)")! }

    private static let nonUUID = "user_12345"
    private static let uuid = "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f"

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

    private func makeCountingClient(
        provider: ProviderBox,
        counter: RequestCounter,
        tokenStore: UserTokenStore? = nil
    ) -> FeedbackClient {
        FeedbackClient(
            configuration: FeedbackClientConfiguration(
                baseURL: baseURL,
                appKey: "app_identitygate"
            ),
            session: makeMockSession(),
            tokenStore: tokenStore,
            turnstileTokenProvider: { _ in
                provider.mark()
                return "tok-gate"
            }
        )
    }

    private func installCountingHandler(counter: RequestCounter) {
        MockURLProtocol.setHandler(forHost: host) { _ in
            counter.increment()
            return (makeHTTPResponse(status: 200), Data())
        }
    }

    private func spec(_ index: Int) -> FeedbackUploadFileSpec {
        FeedbackUploadFileSpec(
            clientFileId: "file-\(index)",
            filename: "f\(index).png",
            contentType: "image/png",
            sizeBytes: 10
        )
    }

    // MARK: Typed rejections on the uuid-typed paths

    @Test(
        "every uuid-typed entry point rejects a non-UUID identity before the Turnstile provider or the network",
        arguments: ["user_12345", "not-a-uuid", "tok-1"]
    )
    func uuidTypedPathsRejectNonUUIDIdentity(token: String) async throws {
        let consulted = ProviderBox()
        let counter = RequestCounter()
        installCountingHandler(counter: counter)
        let client = makeCountingClient(provider: consulted, counter: counter)

        await #expect(throws: FeedbackClientError.invalidIdentityToken) {
            _ = try await client.submitFeatureRequest(
                FeatureRequestDraft(title: "Typed errors", description: "Please", requesterName: "Ada"),
                userToken: token
            )
        }
        await #expect(throws: FeedbackClientError.invalidIdentityToken) {
            _ = try await client.castVote(featureRequestId: "fr-1", userToken: token)
        }
        await #expect(throws: FeedbackClientError.invalidIdentityToken) {
            _ = try await client.removeVote(featureRequestId: "fr-1", userToken: token)
        }
        await #expect(throws: FeedbackClientError.invalidIdentityToken) {
            _ = try await client.createUploadSession(files: [spec(1)], userToken: token)
        }
        await #expect(throws: FeedbackClientError.invalidIdentityToken) {
            _ = try await client.uploadAttachment(
                data: Data([0x89, 0x50]),
                filename: "f.png",
                mimeType: "image/png",
                userToken: token
            )
        }
        // The fileURL one-shot gates before any filesystem access, so a
        // missing file never muddies the assertion.
        await #expect(throws: FeedbackClientError.invalidIdentityToken) {
            _ = try await client.uploadAttachment(
                fileURL: URL(fileURLWithPath: "/nonexistent/identity-gate.png"),
                filename: "f.png",
                mimeType: "image/png",
                userToken: token
            )
        }

        #expect(consulted.wasConsulted == false, "No single-use Turnstile challenge may be minted for a doomed request")
        #expect(counter.value == 0, "No request may be sent for a non-UUID identity")
    }

    @Test("the local rejection carries no request id and no response body")
    func invalidIdentityTokenCarriesNoServerShapedState() {
        let error = FeedbackClientError.invalidIdentityToken
        #expect(error.requestId == nil)
        #expect(error.responseBody == nil)
    }

    // MARK: #493 gate order is unchanged

    @Test("blank and newline-bearing tokens still throw authenticationRequired, not invalidIdentityToken")
    func blankAndNewlineTokensKeepAuthenticationRequired() async throws {
        let consulted = ProviderBox()
        let counter = RequestCounter()
        installCountingHandler(counter: counter)
        let client = makeCountingClient(provider: consulted, counter: counter)

        for blank in ["", "   "] {
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                _ = try await client.submitFeatureRequest(
                    FeatureRequestDraft(title: "Typed errors", description: "Please", requesterName: "Ada"),
                    userToken: blank
                )
            }
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                _ = try await client.castVote(featureRequestId: "fr-1", userToken: blank)
            }
        }
        await #expect(throws: FeedbackClientError.authenticationRequired) {
            _ = try await client.removeVote(featureRequestId: "fr-1", userToken: "tok\nnewline")
        }
        await #expect(throws: FeedbackClientError.authenticationRequired) {
            _ = try await client.createUploadSession(files: [spec(1)], userToken: "   ")
        }

        #expect(consulted.wasConsulted == false)
        #expect(counter.value == 0)
    }

    // MARK: Boundary acceptance on the uuid-typed paths

    @Test("a canonical lowercase UUID and an uppercase UUID both dispatch on castVote")
    func bothUUIDCaseSpellingsDispatch() async throws {
        let consulted = ProviderBox()
        let counter = RequestCounter()
        MockURLProtocol.setHandler(forHost: host) { _ in
            counter.increment()
            return (makeHTTPResponse(), try encodeJSON(["voted": true, "voteCount": 1]))
        }
        let client = makeCountingClient(provider: consulted, counter: counter)

        for identity in [Self.uuid, Self.uuid.uppercased()] {
            let result = try await client.castVote(featureRequestId: "fr-1", userToken: identity)
            #expect(result.voted == true)
        }
        #expect(counter.value == 2)
    }

    @Test("a padded UUID is trimmed and dispatched")
    func paddedUUIDDispatches() async throws {
        let counter = RequestCounter()
        var capturedHeader: String?
        MockURLProtocol.setHandler(forHost: host) { request in
            counter.increment()
            capturedHeader = request.value(forHTTPHeaderField: "X-User-Token")
            return (makeHTTPResponse(), try encodeJSON(["voted": false, "voteCount": 0]))
        }
        let consulted = ProviderBox()
        let client = makeCountingClient(provider: consulted, counter: counter)

        _ = try await client.removeVote(
            featureRequestId: "fr-1",
            userToken: "  \(Self.uuid)  "
        )
        #expect(capturedHeader == Self.uuid)
        #expect(counter.value == 1)
    }

    @Test("createUploadSession falls back to the store token and dispatches when userToken is nil")
    func nilTokenStoreFallbackDispatches() async throws {
        let consulted = ProviderBox()
        let counter = RequestCounter()
        var capturedHeader: String?
        MockURLProtocol.setHandler(forHost: host) { request in
            counter.increment()
            capturedHeader = request.value(forHTTPHeaderField: "X-User-Token")
            return (
                makeHTTPResponse(status: 201),
                try encodeJSON([
                    "session": [
                        "sessionId": "sess-gate",
                        "sessionToken": "stok-gate",
                        "expiresAt": NSNull(),
                        "maxFileSizeBytes": NSNull(),
                        "maxFiles": NSNull()
                    ],
                    "files": [[
                        "clientFileId": "file-1",
                        "uploadId": "upl-gate",
                        "uploadUrl": "/api/v1/uploads/upl-gate",
                        "maxSizeBytes": NSNull()
                    ]]
                ])
            )
        }
        let store = UserTokenStore(appKey: "app_identitygate_fallback")
        let client = makeCountingClient(provider: consulted, counter: counter, tokenStore: store)

        let session = try await client.createUploadSession(files: [spec(1)], userToken: nil)
        #expect(session.session.sessionId == "sess-gate")
        #expect(capturedHeader == store.token, "The store-minted UUID must ride the header unchanged")
        #expect(counter.value == 1)
    }

    // MARK: The plain-string feedback path keeps dispatching

    @Test("submit with a non-UUID token and no attachments still dispatches")
    func feedbackSubmitKeepsPlainStringGate() async throws {
        let consulted = ProviderBox()
        let counter = RequestCounter()
        MockURLProtocol.setHandler(forHost: host) { _ in
            counter.increment()
            return (makeHTTPResponse(), try encodeJSON(["submissionId": "s-1", "forwardedToGithub": true]))
        }
        let client = makeCountingClient(provider: consulted, counter: counter)

        _ = try await client.submit(
            FeedbackDraft(title: "Typed errors", description: "Plain string identity path", platform: .ios),
            userToken: Self.nonUUID
        )
        #expect(counter.value == 1, "The feedback header is a plain string per the live contract — it must still dispatch")
    }
}
