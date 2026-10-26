import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - DecodingErrorMappingTests (API-25)

/// A 2xx response whose body cannot be decoded as the documented schema is a
/// transport/server contract failure, not client data — every public API must
/// surface `.invalidResponse` instead of leaking a raw `Swift.DecodingError`
/// (API-25; the profile sibling is API-26). One test per public client surface
/// so a decode site that stops routing through the shared `decodeSuccess`
/// helper fails here immediately.
@Suite("DecodingErrorMapping", .serialized)
struct DecodingErrorMappingTests {
    static let host = "decode.example.com"

    /// Bodies that are guaranteed decode failures for any documented
    /// response struct: non-JSON text and a JSON array where an object is
    /// expected.
    private static let malformedBodies = ["not json", "[]"]

    func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(Self.host)")!)
    }

    /// Registers a handler answering `status` with `body` and asserts the
    /// operation throws `.invalidResponse` — a raw `DecodingError` (or any
    /// other type) fails the expectation via the catch clauses below.
    private func expectInvalidResponse(
        status: Int,
        body: String,
        operation: @Sendable () async throws -> Void
    ) async {
        MockURLProtocol.setHandler(forHost: Self.host) { _ in
            (
                makeHTTPResponse(status: status, headers: ["X-Request-Id": "req-decode-200"]),
                Data(body.utf8)
            )
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        do {
            try await operation()
            Issue.record("Expected .invalidResponse to be thrown")
        } catch let error as FeedbackClientError {
            #expect(error == .invalidResponse, "Got \(error)")
        } catch {
            Issue.record("Expected FeedbackClientError.invalidResponse, got \(error)")
        }
    }

    // MARK: - Roadmap list & detail (FeatureRequestClient)

    @Test func fetchFeatureRequestsMapsMalformed200ToInvalidResponse() async throws {
        // The issue's scenario: a 200 with an unexpected root object.
        for body in Self.malformedBodies + [#"{"unexpected_root": 123}"#] {
            await expectInvalidResponse(status: 200, body: body) {
                _ = try await self.makeAPIClient().fetchFeatureRequests(userToken: "tok-user")
            }
        }
    }

    @Test func fetchFeatureRequestMapsMalformed200ToInvalidResponse() async throws {
        for body in Self.malformedBodies {
            await expectInvalidResponse(status: 200, body: body) {
                _ = try await self.makeAPIClient().fetchFeatureRequest(id: "fr-detail-1")
            }
        }
    }

    @Test func submitFeatureRequestMapsMalformed201ToInvalidResponse() async throws {
        await expectInvalidResponse(status: 201, body: "[]") {
            _ = try await self.makeAPIClient().submitFeatureRequest(
                FeatureRequestDraft(title: "Title", description: "Long enough body"),
                userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f"
            )
        }
    }

    // MARK: - Votes (FeatureRequestVoteClient)

    @Test func castVoteMapsMalformed200ToInvalidResponse() async throws {
        for body in Self.malformedBodies {
            await expectInvalidResponse(status: 200, body: body) {
                _ = try await self.makeAPIClient().castVote(
                    featureRequestId: "fr-vote-1",
                    userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f"
                )
            }
        }
    }

    @Test func removeVoteMapsMalformed200ToInvalidResponse() async throws {
        for body in Self.malformedBodies {
            await expectInvalidResponse(status: 200, body: body) {
                _ = try await self.makeAPIClient().removeVote(
                    featureRequestId: "fr-vote-1",
                    userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f"
                )
            }
        }
    }

    // MARK: - Changelog (ChangelogClient, including the shared sendJSON path)

    @Test func fetchChangelogMapsMalformed200ToInvalidResponse() async throws {
        for body in Self.malformedBodies {
            await expectInvalidResponse(status: 200, body: body) {
                _ = try await self.makeAPIClient().fetchChangelog()
            }
        }
    }

    @Test func subscribeToChangelogMapsMalformed200ToInvalidResponse() async throws {
        await expectInvalidResponse(status: 200, body: "[]") {
            _ = try await self.makeAPIClient().subscribeToChangelog(
                email: "user@example.com",
                userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f"
            )
        }
    }

    @Test func unsubscribeFromChangelogMapsMalformed200ToInvalidResponse() async throws {
        await expectInvalidResponse(status: 200, body: "[]") {
            _ = try await self.makeAPIClient().unsubscribeFromChangelog(token: "tok-unsub")
        }
    }

    // MARK: - Comments (CommentClient)

    @Test func fetchCommentsMapsMalformed200ToInvalidResponse() async throws {
        for body in Self.malformedBodies {
            await expectInvalidResponse(status: 200, body: body) {
                _ = try await self.makeAPIClient().fetchComments(featureRequestId: "fr-123", limit: 20)
            }
        }
    }

    @Test func postCommentMapsMalformed201ToInvalidResponse() async throws {
        await expectInvalidResponse(status: 201, body: "[]") {
            _ = try await self.makeAPIClient().postComment(
                featureRequestId: "fr-123",
                draft: CommentDraft(body: "A comment body"),
                userToken: "tok-user"
            )
        }
    }

    // MARK: - Feedback submission (FeedbackClient)

    @Test func submitFeedbackMapsMalformed201ToInvalidResponse() async throws {
        await expectInvalidResponse(status: 201, body: "[]") {
            _ = try await self.makeAPIClient().submit(
                FeedbackDraft(title: "Title", description: "Body text", platform: .ios)
            )
        }
    }

    // MARK: - Upload sessions (UploadSession)

    @Test func createUploadSessionMapsMalformed201ToInvalidResponse() async throws {
        await expectInvalidResponse(status: 201, body: "[]") {
            _ = try await self.makeAPIClient().createUploadSession(
                files: [FeedbackUploadFileSpec(
                    clientFileId: "file-1",
                    filename: "screenshot.png",
                    contentType: "image/png",
                    sizeBytes: 128
                )],
                userToken: nil
            )
        }
    }

    // MARK: - Weekly digest (WeeklyDigestUnsubscribe)

    @Test func unsubscribeFromWeeklyDigestMapsMalformed200ToInvalidResponse() async throws {
        await expectInvalidResponse(status: 200, body: "[]") {
            _ = try await self.makeAPIClient().unsubscribeFromWeeklyDigest(token: "tok-digest")
        }
    }

    // MARK: - End-user identity (EndUserClient)

    @Test func linkEndUserMapsMalformed200ToInvalidResponse() async throws {
        await expectInvalidResponse(status: 200, body: "[]") {
            _ = try await self.makeAPIClient().linkEndUser(
                sessionToken: "sess-token",
                userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f"
            )
        }
    }

    @Test func eraseMyDataMapsMalformed200ToInvalidResponse() async throws {
        await expectInvalidResponse(status: 200, body: "[]") {
            _ = try await self.makeAPIClient().eraseMyData(userToken: "tok-user")
        }
    }

    // MARK: - User attributes (UserAttributesClient, shared sendJSON path)

    @Test func updateUserAttributesMapsMalformed200ToInvalidResponse() async throws {
        await expectInvalidResponse(status: 200, body: "[]") {
            _ = try await self.makeAPIClient().updateUserAttributes(userToken: "tok-user")
        }
    }

    // MARK: - Public config surfaces (PublicAPI generic decode)

    @Test func fetchColumnsMapsMalformed200ToInvalidResponse() async throws {
        for body in Self.malformedBodies {
            await expectInvalidResponse(status: 200, body: body) {
                _ = try await self.makeAPIClient().fetchColumns()
            }
        }
    }

    // MARK: - The single remaining meaning of `.invalidResponse` (issue #614)

    /// A response that is not an `HTTPURLResponse` at all — the transport
    /// fault `.invalidResponse` was coined for — still maps there, never to
    /// a typed local-input case or a not-found error.
    @Test func nonHTTPResponseMapsToInvalidResponse() async throws {
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            (
                URLResponse(
                    url: request.url ?? URL(string: "https://\(Self.host)")!,
                    mimeType: "application/json",
                    expectedContentLength: 0,
                    textEncodingName: nil
                ),
                Data()
            )
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        do {
            _ = try await self.makeAPIClient().fetchFeatureRequests(userToken: "tok-user")
            Issue.record("Expected .invalidResponse to be thrown")
        } catch let error as FeedbackClientError {
            #expect(error == .invalidResponse, "Got \(error)")
        } catch {
            Issue.record("Expected FeedbackClientError.invalidResponse, got \(error)")
        }
    }
}
