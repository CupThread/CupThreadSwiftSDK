import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Vote shipNotifyEmail opt-in contract (#258)

/// Verifies that `FeedbackClient.toggleVote` exposes the public API's
/// optional `shipNotifyEmail` opt-in: the field rides on the vote request
/// only when the caller provides one, whitespace is trimmed, absent/blank
/// values keep the historical payload shape (field omitted, not encoded as
/// null), and the server's non-fatal `email_not_verified` warning still
/// surfaces through `VoteResult.warning`.
@Suite("VoteShipNotifyEmail", .serialized)
struct VoteShipNotifyEmailTests {
    private static let host = "vote-ship-notify.example.com"

    private static func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(host)")!)
    }

    @Test func toggleVoteOmitsShipNotifyEmailByDefault() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(status: 200), try encodeJSON(["voted": true, "voteCount": 7]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        let result = try await Self.makeAPIClient().toggleVote(
            featureRequestId: "fr-1",
            userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f"
        )
        #expect(result.voted == true)

        let data = try #require(capture.value)
        let dict = try #require(parseJSONDict(data))
        #expect(dict["shipNotifyEmail"] == nil)
        // The historical payload shape is otherwise unchanged.
        #expect(dict["appKey"] as? String == "app_testkey123456")
        #expect(dict["userToken"] as? String == "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f")
        #expect(dict.count == 2)
    }

    @Test func toggleVoteSendsShipNotifyEmailWhenProvided() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(status: 200), try encodeJSON(["voted": true, "voteCount": 7]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        _ = try await Self.makeAPIClient().toggleVote(
            featureRequestId: "fr-1",
            userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f",
            shipNotifyEmail: "voter@example.com"
        )

        let data = try #require(capture.value)
        let dict = try #require(parseJSONDict(data))
        #expect(dict["shipNotifyEmail"] as? String == "voter@example.com")
        #expect(dict.count == 3)
    }

    @Test func castVoteSendsShipNotifyEmailWhenProvided() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(status: 200), try encodeJSON(["voted": true, "voteCount": 7]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        _ = try await Self.makeAPIClient().castVote(
            featureRequestId: "fr-1",
            userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f",
            shipNotifyEmail: "voter@example.com"
        )

        let data = try #require(capture.value)
        let dict = try #require(parseJSONDict(data))
        #expect(dict["shipNotifyEmail"] as? String == "voter@example.com")
        #expect(dict.count == 3)
    }

    @Test func toggleVoteTrimsShipNotifyEmail() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(status: 200), try encodeJSON(["voted": true, "voteCount": 7]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        _ = try await Self.makeAPIClient().toggleVote(
            featureRequestId: "fr-1",
            userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f",
            shipNotifyEmail: "  voter@example.com \n"
        )

        let data = try #require(capture.value)
        let dict = try #require(parseJSONDict(data))
        #expect(dict["shipNotifyEmail"] as? String == "voter@example.com")
    }

    @Test func toggleVoteTreatsWhitespaceOnlyShipNotifyEmailAsAbsent() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(status: 200), try encodeJSON(["voted": true, "voteCount": 7]))
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        _ = try await Self.makeAPIClient().toggleVote(
            featureRequestId: "fr-1",
            userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f",
            shipNotifyEmail: "   "
        )

        let data = try #require(capture.value)
        let dict = try #require(parseJSONDict(data))
        #expect(dict["shipNotifyEmail"] == nil)
        #expect(dict.count == 2)
    }

    @Test func toggleVoteSurfacesEmailNotVerifiedWarning() async throws {
        MockURLProtocol.setHandler(forHost: Self.host) { _ in
            (
                makeHTTPResponse(status: 200),
                try encodeJSON([
                    "voted": true,
                    "voteCount": 1,
                    "warning": [
                        "code": "email_not_verified",
                        "error": "Ship notifications on this board are bound to your signed-in email address"
                    ]
                ])
            )
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        let result = try await Self.makeAPIClient().toggleVote(
            featureRequestId: "fr-1",
            userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f",
            shipNotifyEmail: "unverified@example.com"
        )
        // The vote itself is recorded; the rejected opt-in comes back as a
        // non-fatal warning instead of an error.
        #expect(result.voted == true)
        #expect(result.voteCount == 1)
        #expect(result.warning?.isEmailNotVerified == true)
    }

    @Test func toggleVoteSurfacesShipNotifyVerificationFailedWarning() async throws {
        // Issue #626: an anonymous opt-in whose Turnstile verification the
        // server found missing or rejected still records the vote but answers
        // with the ship_notify_verification_failed warning — no consent row,
        // no confirmation email.
        MockURLProtocol.setHandler(forHost: Self.host) { _ in
            (
                makeHTTPResponse(status: 200),
                try encodeJSON([
                    "voted": true,
                    "voteCount": 3,
                    "warning": [
                        "code": "ship_notify_verification_failed",
                        "error": "Human verification failed, so the ship-notification opt-in "
                            + "was not recorded. Complete the verification and try again."
                    ]
                ])
            )
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        let result = try await Self.makeAPIClient().toggleVote(
            featureRequestId: "fr-1",
            userToken: "3f2c9a1e-7b4d-4c8a-9e2f-1a2b3c4d5e6f",
            shipNotifyEmail: "anon@example.com"
        )
        #expect(result.voted == true)
        #expect(result.voteCount == 3)
        #expect(result.warning?.isShipNotifyVerificationFailed == true)
        #expect(result.warning?.isEmailNotVerified == false)
    }
}
