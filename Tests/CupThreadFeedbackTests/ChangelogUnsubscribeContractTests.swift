import Foundation
import Testing
@testable import CupThreadFeedback

/// Tests for the changelog-unsubscribe contract after SaaS #635: a token
/// whose signature verifies for the app unsubscribes even after its `exp`
/// has passed and even when the app's public surfaces are disabled, so the
/// previously-failing 403 on a privatized board now means the token was
/// missing or not valid and maps to `.forbidden` (#294) like the other
/// public routes' permission denials.
///
/// The suite uses its own mock host so it cannot stomp (or be stomped by)
/// suites that share a different host's handler.
@Suite("ChangelogUnsubscribeContract", .serialized)
struct ChangelogUnsubscribeContractTests {
    private let host = "unsubscribe-contract.example.com"
    private var baseURL: URL { URL(string: "https://\(host)")! }

    private func makeUnsubscribeCall(token: String) async throws -> ChangelogUnsubscribeResult {
        try await makeClient(baseURL: baseURL).unsubscribeFromChangelog(token: token)
    }

    @Test func unsubscribeHonorsExpiredButSignedToken() async throws {
        // #294: an authentic signature past the token's 90-day `exp` still
        // unsubscribes with the unchanged `200 {"unsubscribed": true}` body.
        // The SDK must treat the 200 as final and never judge a token
        // locally, so links already sitting in inboxes keep working.
        MockURLProtocol.setHandler(forHost: host) { request in
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            return (makeHTTPResponse(), try encodeJSON(["unsubscribed": true]))
        }

        let result = try await makeUnsubscribeCall(token: "expired-but-signed-token")

        #expect(result.unsubscribed == true)
    }

    @Test func unsubscribeMapsCodeless403ToForbiddenWhenPublicSurfacesDisabled() async throws {
        // On an app whose public surfaces are disabled, a missing or invalid
        // token answers the code-less 403 permission denial (#294). #294
        // maps it to `.forbidden` instead of `.unexpectedStatus`, consistent
        // with the sibling public endpoints (#239).
        MockURLProtocol.setHandler(forHost: host) { _ in
            (
                makeHTTPResponse(status: 403, headers: ["X-Request-Id": "req-unsub-403"]),
                try encodeJSON(["error": "Public surfaces are disabled for this app"])
            )
        }
        do {
            _ = try await makeUnsubscribeCall(token: "stale-token")
            Issue.record("Expected forbidden")
        } catch let error as FeedbackClientError {
            guard case .forbidden(let message, let requestId) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(message == "Public surfaces are disabled for this app")
            #expect(requestId == "req-unsub-403")
            // Surfaces routing through FriendlyError show curated permission
            // copy — the raw server text and generic request-failed copy both
            // stay out of the UI.
            let display = FriendlyError.message(for: error)
            #expect(display == CupThreadStrings.tr("cupthread.error.forbidden") + " (request id: req-unsub-403)")
            #expect(!display.contains("Public surfaces are disabled"))
        }
    }
}
