import Foundation
import Testing
@testable import CupThreadFeedback

// Regression tests for SEC-30 (#497): every public FeedbackClient method that
// accepts a caller-supplied `userToken` must validate it locally via
// `validatedUserToken` before any URLRequest is built or the Turnstile token
// provider is consulted. Blank, whitespace-only, or newline-bearing tokens
// throw `FeedbackClientError.authenticationRequired` instead of being silently
// dropped from `X-User-Token` or replaced with `tokenStore.token`; `nil` on
// optional-token endpoints preserves anonymous/store-fallback semantics, and
// whitespace-padded valid tokens are trimmed once.
@Suite("SEC30UserTokenValidation", .serialized)
struct Sec30UserTokenValidationTests {
    static let apiHost = "sec30-user-token-validation.example.com"
    static let paddedToken = "  9a8b7c1d-2e3f-4a5b-8c9d-0e1f2a3b4c5d  "
    static let trimmedToken = "9a8b7c1d-2e3f-4a5b-8c9d-0e1f2a3b4c5d"
    static let invalidTokens = [
        "",
        "   ",
        "\n",
        " \n\t ",
        "tok\n123",
        "tok\r\n123",
        "tok\r123",
        "tok\r\nInjected: evil",
        "tok\u{0085}123",
        "tok\u{2028}123",
        "tok\u{2029}123"
    ]

    final class ProviderCounter: @unchecked Sendable {
        var mintedAny = false
    }

    static func makeValidatedClient(
        providerCalls: ProviderCounter? = nil,
        tokenStore: UserTokenStore? = nil
    ) -> FeedbackClient {
        let provider: (@Sendable (TurnstileChallenge) async -> String?)?
        if let providerCalls {
            provider = { _ in
                providerCalls.mintedAny = true
                return "provider-minted-token"
            }
        } else {
            provider = nil
        }
        return FeedbackClient(
            configuration: FeedbackClientConfiguration(
                baseURL: URL(string: "https://\(apiHost)")!,
                appKey: "app_sec30testkey123"
            ),
            session: makeMockSession(),
            tokenStore: tokenStore,
            turnstileTokenProvider: provider
        )
    }

    static func clearHostHandler() {
        MockURLProtocol.setHandler(forHost: apiHost, nil)
    }

    // MARK: - Shared validator unit tests

    @Test func validatedUserTokenTrimsAndRejectsInvalidValues() throws {
        let client = Self.makeValidatedClient()
        let optionalNil: String? = nil
        #expect(try client.validatedUserToken(optionalNil) == nil)
        #expect(try client.validatedUserToken(Self.paddedToken) == Self.trimmedToken)
        let optionalPadded: String? = Self.paddedToken
        #expect(try client.validatedUserToken(optionalPadded) == Self.trimmedToken)

        for invalid in Self.invalidTokens {
            #expect(throws: FeedbackClientError.authenticationRequired) {
                _ = try client.validatedUserToken(invalid)
            }
            let optionalInvalid: String? = invalid
            #expect(throws: FeedbackClientError.authenticationRequired) {
                _ = try client.validatedUserToken(optionalInvalid)
            }
        }
    }

    // MARK: - fetchFeatureRequests

    @Test func fetchFeatureRequestsRejectsInvalidUserTokensWithoutNetwork() async {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["requests": [String](), "total": 0]))
        }
        defer { Self.clearHostHandler() }

        for invalid in Self.invalidTokens {
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                _ = try await Self.makeValidatedClient().fetchFeatureRequests(userToken: invalid)
            }
        }

        #expect(capture.value == nil)
    }

    // MARK: - fetchFeatureRequest & getFeatureRequest

    @Test func fetchFeatureRequestRejectsInvalidNonNilUserTokensWithoutNetwork() async {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), Data("{}".utf8))
        }
        defer { Self.clearHostHandler() }

        for invalid in Self.invalidTokens {
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                _ = try await Self.makeValidatedClient().fetchFeatureRequest(id: "fr-1", userToken: invalid)
            }
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                _ = try await Self.makeValidatedClient().getFeatureRequest(id: "fr-1", userToken: invalid)
            }
        }

        #expect(capture.value == nil)
    }

    @Test func fetchFeatureRequestTrimsPaddedTokenAndPreservesNil() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["request": [
                "id": "fr-1",
                "appId": "app-1",
                "title": "Title",
                "description": "Description",
                "status": "open",
                "approved": true,
                "voteCount": 1,
                "hasVoted": true,
                "isOwnRequest": false,
                "createdAt": "2026-10-01T00:00:00Z",
                "updatedAt": "2026-10-01T00:00:00Z"
            ]]))
        }
        defer { Self.clearHostHandler() }

        _ = try await Self.makeValidatedClient().fetchFeatureRequest(id: "fr-1", userToken: Self.paddedToken)
        let reqWithToken = try #require(capture.value)
        #expect(reqWithToken.value(forHTTPHeaderField: "X-User-Token") == Self.trimmedToken)

        capture.value = nil
        _ = try await Self.makeValidatedClient().fetchFeatureRequest(id: "fr-1", userToken: nil)
        let reqNil = try #require(capture.value)
        #expect(reqNil.value(forHTTPHeaderField: "X-User-Token") == nil)
    }

    // MARK: - submit (feedback)

    @Test func submitRejectsInvalidNonNilUserTokensWithoutNetworkOrTurnstileMint() async {
        let capture = CaptureBox<URLRequest>()
        let providerCalls = ProviderCounter()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(status: 201), try encodeJSON(["submissionId": "sub-1"]))
        }
        defer { Self.clearHostHandler() }

        let plainDraft = FeedbackDraft(title: "Bug report", description: "Detailed steps here", platform: .ios)
        var attachmentDraft = plainDraft
        attachmentDraft.attachments = [
            FeedbackAttachment(
                kind: .image,
                uploadId: "upl-1",
                key: "upl-1",
                url: URL(string: "https://\(Self.apiHost)/1.png")!
            )
        ]

        for invalid in Self.invalidTokens {
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                _ = try await Self.makeValidatedClient(providerCalls: providerCalls).submit(
                    plainDraft,
                    userToken: invalid
                )
            }
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                _ = try await Self.makeValidatedClient(providerCalls: providerCalls).submit(
                    attachmentDraft,
                    userToken: invalid
                )
            }
        }

        #expect(capture.value == nil)
        #expect(!providerCalls.mintedAny)
    }

    @Test func submitTrimsPaddedTokenAndPreservesNilFallback() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(status: 201), try encodeJSON(["submissionId": "sub-1"]))
        }
        defer { Self.clearHostHandler() }

        let isolated = makeIsolatedTokenStore()
        let client = Self.makeValidatedClient(tokenStore: isolated.store)
        let plainDraft = FeedbackDraft(title: "Bug report", description: "Detailed steps here", platform: .ios)

        _ = try await client.submit(plainDraft, userToken: Self.paddedToken)
        #expect(try #require(capture.value).value(forHTTPHeaderField: "X-User-Token") == Self.trimmedToken)

        capture.value = nil
        _ = try await client.submit(plainDraft, userToken: nil)
        #expect(try #require(capture.value).value(forHTTPHeaderField: "X-User-Token") == nil)

        var attachmentDraft = plainDraft
        attachmentDraft.attachments = [
            FeedbackAttachment(
                kind: .image,
                uploadId: "upl-1",
                key: "upl-1",
                url: URL(string: "https://\(Self.apiHost)/1.png")!
            )
        ]
        capture.value = nil
        _ = try await client.submit(attachmentDraft, userToken: nil)
        #expect(try #require(capture.value).value(forHTTPHeaderField: "X-User-Token") == isolated.store.token)
    }

    // MARK: - createUploadSession & uploadAttachment

    @Test func createUploadSessionAndUploadAttachmentRejectInvalidUserTokensWithoutNetworkOrTurnstileMint() async throws {
        let capture = CaptureBox<URLRequest>()
        let providerCalls = ProviderCounter()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(status: 201), Data("{}".utf8))
        }
        defer { Self.clearHostHandler() }

        let spec = FeedbackUploadFileSpec(
            clientFileId: "file-1",
            filename: "shot.png",
            contentType: "image/png",
            sizeBytes: 4
        )
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sec30-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        for invalid in Self.invalidTokens {
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                _ = try await Self.makeValidatedClient(providerCalls: providerCalls).createUploadSession(
                    files: [spec],
                    userToken: invalid
                )
            }
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                _ = try await Self.makeValidatedClient(providerCalls: providerCalls).uploadAttachment(
                    data: Data([0x89, 0x50, 0x4E, 0x47]),
                    filename: "shot.png",
                    mimeType: "image/png",
                    userToken: invalid
                )
            }
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                _ = try await Self.makeValidatedClient(providerCalls: providerCalls).uploadAttachment(
                    fileURL: tempURL,
                    filename: "shot.png",
                    mimeType: "image/png",
                    userToken: invalid
                )
            }
        }

        #expect(capture.value == nil)
        #expect(!providerCalls.mintedAny)
    }

    @Test func createUploadSessionTrimsPaddedTokenAndPreservesNilStoreFallback() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (
                makeHTTPResponse(status: 201),
                try encodeJSON([
                    "session": ["sessionId": "s-1", "sessionToken": "stok-1"],
                    "files": [[
                        "clientFileId": "file-1",
                        "uploadId": "upl-1",
                        "uploadUrl": "https://\(Self.apiHost)/api/v1/uploads/upl-1"
                    ]]
                ])
            )
        }
        defer { Self.clearHostHandler() }

        let isolated = makeIsolatedTokenStore()
        let client = Self.makeValidatedClient(tokenStore: isolated.store)
        let spec = FeedbackUploadFileSpec(
            clientFileId: "file-1",
            filename: "shot.png",
            contentType: "image/png",
            sizeBytes: 4
        )

        _ = try await client.createUploadSession(files: [spec], userToken: Self.paddedToken)
        #expect(try #require(capture.value).value(forHTTPHeaderField: "X-User-Token") == Self.trimmedToken)

        capture.value = nil
        _ = try await client.createUploadSession(files: [spec], userToken: nil)
        #expect(try #require(capture.value).value(forHTTPHeaderField: "X-User-Token") == isolated.store.token)
    }

    // MARK: - postComment

    @Test func postCommentRejectsInvalidUserTokensWithoutNetwork() async {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(status: 201), Data("{}".utf8))
        }
        defer { Self.clearHostHandler() }

        for invalid in Self.invalidTokens {
            await #expect(throws: FeedbackClientError.authenticationRequired) {
                _ = try await Self.makeValidatedClient().postComment(
                    featureRequestId: "fr-1",
                    draft: CommentDraft(body: "Valid comment body"),
                    userToken: invalid
                )
            }
        }

        #expect(capture.value == nil)
    }

    @Test func postCommentTrimsPaddedUserToken() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (
                makeHTTPResponse(status: 201),
                try encodeJSON([
                    "comment": [
                        "id": "c-1",
                        "featureRequestId": "fr-1",
                        "body": "Valid comment body",
                        "createdAt": "2026-10-01T00:00:00Z"
                    ]
                ])
            )
        }
        defer { Self.clearHostHandler() }

        _ = try await Self.makeValidatedClient().postComment(
            featureRequestId: "fr-1",
            draft: CommentDraft(body: "Valid comment body"),
            userToken: Self.paddedToken
        )

        #expect(try #require(capture.value).value(forHTTPHeaderField: "X-User-Token") == Self.trimmedToken)
    }
}
