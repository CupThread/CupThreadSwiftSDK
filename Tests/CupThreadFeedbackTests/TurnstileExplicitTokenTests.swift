import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Explicit challenge tokens + composer wiring (#53 Phase 2)

/// Pins the second half of the in-SDK challenge flow: a token minted by
/// ``TurnstileChallengeSheet`` is sent verbatim on the first attempt, a
/// rejected explicit token throws after that attempt when no provider is
/// installed, and both composers route a gate rejection into the sheet
/// without touching their drafts.
@Suite("Turnstile explicit token", .serialized)
struct TurnstileExplicitTokenTests {
    static let host = "turnstile-explicit.example.com"
    static let baseURL = URL(string: "https://\(host)")!

    let feedbackReceipt = ["submissionId": "s-1", "forwardedToGithub": true] as [String: Any]
    let featureRequestReceipt = ["featureRequestId": "fr-1", "pending": true] as [String: Any]

    // MARK: Helpers

    final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [Data] = []

        func append(_ request: URLRequest) {
            lock.lock()
            defer { lock.unlock() }
            if let data = bodyData(from: request) {
                bodies.append(data)
            }
        }

        var allBodies: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return bodies
        }
    }

    final class TokenProvider: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0

        func next() -> String? {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            return "provider-token"
        }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    private func makeClient(
        turnstileTokenProvider: (@Sendable (TurnstileChallenge) async -> String?)? = nil
    ) -> FeedbackClient {
        FeedbackClient(
            configuration: FeedbackClientConfiguration(baseURL: Self.baseURL, appKey: "app_explicit1"),
            session: makeMockSession(),
            turnstileTokenProvider: turnstileTokenProvider
        )
    }

    private static func turnstileRejection() throws -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: URL(string: "https://\(host)/api/v1/feedback")!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json", "X-Request-Id": "req-explicit-1"]
        )!
        return (response, try encodeJSON([
            "error": "Human verification (Turnstile) is required",
            "code": "turnstile_required"
        ]))
    }

    // MARK: - Wire encoding

    @Test func feedbackSubmissionSendsExplicitToken() async throws {
        let log = RequestLog()
        MockURLProtocol.setHandler(forHost: Self.host) { [feedbackReceipt] request in
            log.append(request)
            return (makeHTTPResponse(status: 200), try encodeJSON(feedbackReceipt))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        _ = try await makeClient().submit(
            FeedbackDraft(title: "Title", description: "Description", platform: .ios),
            userToken: "user-1",
            turnstileToken: "sheet-token-1"
        )

        let body = try #require(log.allBodies.first)
        let json = try #require(parseJSONDict(body))
        #expect(json["turnstileToken"] as? String == "sheet-token-1")
    }

    @Test func featureRequestSubmissionSendsExplicitToken() async throws {
        let log = RequestLog()
        MockURLProtocol.setHandler(forHost: Self.host) { [featureRequestReceipt] request in
            log.append(request)
            return (makeHTTPResponse(status: 201), try encodeJSON(featureRequestReceipt))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        _ = try await makeClient().submitFeatureRequest(
            FeatureRequestDraft(title: "Title", description: "Description"),
            userToken: "user-1",
            turnstileToken: "sheet-token-2"
        )

        let body = try #require(log.allBodies.first)
        let json = try #require(parseJSONDict(body))
        #expect(json["turnstileToken"] as? String == "sheet-token-2")
        #expect(json["requesterToken"] as? String == "user-1")
    }

    @Test func explicitTokenSkipsTheProviderOnTheFirstAttempt() async throws {
        let provider = TokenProvider()
        MockURLProtocol.setHandler(forHost: Self.host) { [feedbackReceipt] _ in
            (makeHTTPResponse(status: 200), try encodeJSON(feedbackReceipt))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        _ = try await makeClient(turnstileTokenProvider: { _ in provider.next() }).submit(
            FeedbackDraft(title: "Title", description: "Description", platform: .ios),
            turnstileToken: "sheet-token-3"
        )

        #expect(provider.callCount == 0)
    }

    @Test func attachmentUploadSendsExplicitTokenOnSessionCreation() async throws {
        let log = RequestLog()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            if request.url?.path.contains("/api/v1/uploads/sessions") == true {
                log.append(request)
                return (makeHTTPResponse(status: 201), try Self.uploadSessionJSON())
            }
            // The slot PUT streams the bytes; only session creation is gated.
            return (makeHTTPResponse(status: 200), Data())
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        _ = try await makeClient().uploadAttachment(
            data: Data("hello".utf8),
            filename: "screenshot.png",
            mimeType: "image/png",
            userToken: "user-1",
            turnstileToken: "{{SECRET_sheetminted}}"
        )

        let body = try #require(log.allBodies.first)
        let json = try #require(parseJSONDict(body))
        #expect(json["turnstileToken"] as? String == "{{SECRET_sheetminted}}")
    }

    private static func uploadSessionJSON() throws -> Data {
        try encodeJSON([
            "session": [
                "sessionId": "sess-explicit-1",
                "sessionToken": "stok-explicit",
                "expiresAt": NSNull(),
                "maxFileSizeBytes": NSNull(),
                "maxFiles": NSNull()
            ],
            "files": [[
                "clientFileId": "file-1",
                "uploadId": "upl-explicit-1",
                "uploadUrl": "https://\(host)/api/v1/uploads/upl-explicit-1",
                "maxSizeBytes": NSNull()
            ]]
        ])
    }

    @Test func rejectedExplicitTokenThrowsAfterSingleAttemptWithoutProvider() async throws {
        let log = RequestLog()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            log.append(request)
            return try Self.turnstileRejection()
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        do {
            _ = try await makeClient().submit(
                FeedbackDraft(title: "Title", description: "Description", platform: .ios),
                turnstileToken: "expired-sheet-token"
            )
            Issue.record("Expected a turnstileRequired rejection")
        } catch let error as FeedbackClientError {
            guard case .turnstileRequired = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
        }
        #expect(log.allBodies.count == 1, "the sheet owns retry policy; a rejected explicit token must not loop")
        let body = try #require(log.allBodies.first)
        let json = try #require(parseJSONDict(body))
        #expect(json["turnstileToken"] as? String == "expired-sheet-token")
    }

    @Test func notConfiguredRejectionIsAServerFailureNotSignInGuidance() async throws {
        // The deployment enforces Turnstile without a secret: minting a token
        // cannot help, and the 403 must not read as "sign in" or open the
        // challenge sheet (SaaS #1052). It stays a server-side failure.
        MockURLProtocol.setHandler(forHost: Self.host) { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://\(Self.host)/api/v1/feedback")!,
                statusCode: 403,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, try encodeJSON([
                "error": "Human verification is required but not configured",
                "code": "turnstile_not_configured"
            ]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        do {
            _ = try await makeClient().submit(
                FeedbackDraft(title: "Title", description: "Description", platform: .ios)
            )
            Issue.record("Expected a server-side failure")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, _, _) = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(code == 403)
        }
    }

    // MARK: - Composer wiring (source-scan: @State writes are not observable
    // on a unit-constructed view, the same pattern as
    // `CommentsViewSubmitLoadErrorTests`)

    private static func source(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            directory.deleteLastPathComponent()
            let candidate = directory
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CupThreadFeedback", isDirectory: true)
                .appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    @Test func feedbackComposerPresentsTheSheetAndSubmitsWithItsToken() throws {
        let content = try Self.source("FeedbackComposerView.swift")

        #expect(content.contains(".turnstileChallengeSheet($pendingChallenge)"))
        #expect(content.contains(
            "presentChallengeIfNeeded(for: error, "
                + "challenge: .feedback(appKey: currentClient.configuration.appKey))"
        ))
        #expect(content.contains("turnstileToken: turnstileToken"))
        #expect(content.contains("cancel: { errorMessage = FriendlyError.message(for: error) }"))

        // The failure path must keep the draft: no reset and no draft write
        // between the catch and the helper's declaration.
        let catchMarker = "} catch {\n            guard !error.isSdkCancellation else { return }\n"
            + "            if presentChallengeIfNeeded"
        let catchRange = try #require(content.range(of: catchMarker))
        let functionEnd = try #require(
            content.range(of: "/// Cancels the in-flight upload", range: catchRange.upperBound..<content.endIndex)
        )
        let failurePath = content[catchRange.lowerBound..<functionEnd.lowerBound]
        #expect(!failurePath.contains("resetForm()"))
        #expect(!failurePath.contains("draft = "))
    }

    @Test func featureRequestComposerPresentsTheSheetAndSubmitsWithItsToken() throws {
        let content = try Self.source("FeatureRequestComposeView.swift")

        #expect(content.contains(".turnstileChallengeSheet($pendingChallenge)"))
        #expect(content.contains("presentChallengeIfNeeded(for: error)"))
        #expect(content.contains("for: .featureRequest(appKey: client.configuration.appKey)"))
        #expect(content.contains("turnstileToken: turnstileToken"))
        #expect(content.contains("cancel: { submitError = FriendlyError.message(for: error) }"))

        let catchMarker = "} catch {\n            guard !error.isSdkCancellation else { return }\n"
            + "            if presentChallengeIfNeeded"
        let catchRange = try #require(content.range(of: catchMarker))
        let helper = try #require(
            content.range(of: "private func presentChallengeIfNeeded", range: catchRange.upperBound..<content.endIndex)
        )
        let failurePath = content[catchRange.lowerBound..<helper.lowerBound]
        #expect(!failurePath.contains("draft = FeatureRequestDraft()"))
    }

    @Test func feedbackComposerResumesAnAttachmentUploadWithTheMintedToken() throws {
        let content = try Self.source("FeedbackComposerView.swift")

        // The upload-session gate is the same feedback binding: the composer
        // presents the sheet, then retries the spooled file with the token.
        #expect(content.contains("try await sendPreparedPhoto(prepared, uploadId: uploadId, turnstileToken: nil)"))
        #expect(content.contains("sendPreparedPhoto(prepared, uploadId: uploadId, turnstileToken: token)"))
        #expect(content.contains("turnstileToken: turnstileToken"))
        #expect(content.contains("for: .feedback(appKey: client.configuration.appKey)"))
    }

    @Test func challengeSheetUsesThePersistentWebKitStore() throws {
        // Cloudflare's bot heuristics reject ephemeral stores; the sheet must
        // keep the default store so the hosted page can mint tokens.
        let content = try Self.source("TurnstileChallengeSheet.swift")

        #expect(content.contains("configuration.websiteDataStore = .default()"))
        #expect(content.contains("static let bridgeName = \"turnstileBridge\""))
    }
}
