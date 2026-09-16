import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Submission quota 402 mapping (#112)

@Suite("SubmissionQuotaErrors", .serialized)
struct SubmissionQuotaErrorTests {
    static let apiHost = "apisync-quota.example.com"

    @Test func featureRequestSubmitMapsQuota402ToSubmissionQuotaExceeded() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 402), try encodeJSON([
                "error": "Monthly submission quota reached.",
                "code": "tier_limit_submissions"
            ]))
        }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
        do {
            _ = try await client.submitFeatureRequest(
                FeatureRequestDraft(title: "Title", description: "Description"),
                userToken: "tok"
            )
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .submissionQuotaExceeded(let message) = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(message == "Monthly submission quota reached.")
        }
    }

    @Test func featureRequestSubmitMapsInactiveSubscription402ToTypedError() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 402), try encodeJSON([
                "error": "Subscription inactive.",
                "code": "subscription_inactive"
            ]))
        }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
        do {
            _ = try await client.submitFeatureRequest(
                FeatureRequestDraft(title: "Title", description: "Description"),
                userToken: "tok"
            )
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .subscriptionInactive = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(error.errorDescription?.contains("Submissions are unavailable") == true)
        }
    }

    @Test func feedbackSubmitMapsQuota402ToSubmissionQuotaExceeded() async throws {
        // POST /api/v1/feedback enforces the same quota contract as
        // POST /api/v1/feature-requests; the shared validateResponse
        // must map both.
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 402), try encodeJSON([
                "error": "Monthly submission quota reached.",
                "code": "tier_limit_submissions"
            ]))
        }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
        do {
            _ = try await client.submit(
                FeedbackDraft(title: "Title", description: "Description", platform: .ios),
                userToken: "tok"
            )
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .submissionQuotaExceeded = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(error.errorDescription?.contains("submission limit") == true)
        }
    }

    @Test func unrecognized402CodeFallsBackToUnexpectedStatusWithRequestID() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://\(Self.apiHost)/api/v1/feature-requests")!,
                statusCode: 402,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json", "X-Request-Id": "req-402-1"]
            )!
            return (response, try encodeJSON(["error": "Payment required.", "code": "future_code"]))
        }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
        do {
            _ = try await client.submitFeatureRequest(
                FeatureRequestDraft(title: "Title", description: "Description"),
                userToken: "tok"
            )
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, let message, let requestId) = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(code == 402)
            #expect(message == "Payment required.")
            #expect(requestId == "req-402-1")
        }
    }

    @Test func quotaErrorDescriptionsAreUserFacing() {
        let quota = FeedbackClientError.submissionQuotaExceeded(message: "server detail")
        let inactive = FeedbackClientError.subscriptionInactive(message: "server detail")
        #expect(
            quota.errorDescription
                == "This app has reached its submission limit for this month. Please try again later."
        )
        #expect(
            inactive.errorDescription
                == "Submissions are unavailable for this app right now. Please try again later."
        )
    }
}
