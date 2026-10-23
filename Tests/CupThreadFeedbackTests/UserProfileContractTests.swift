import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Corrected profile response contract (issue #505)

@Suite("UserProfileContract", .serialized)
struct UserProfileContractTests {
    static let apiHost = "profile-contract.example.com"
    static let profileID = "u_1a2b3c4d5e6f708192a3b4c5d6e7f809"

    private func makeContractClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
    }

    @Test func fetchUserProfileMapsMissingPublicAppsToInvalidResponse() async throws {
        // The corrected response always carries `publicApps`; a payload
        // without it is contract drift, never a silently empty profile
        // (issue #505).
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            let body: [String: Any] = [
                "profile": [
                    "clerkUserId": Self.profileID,
                    "displayName": NSNull(),
                    "avatarUrl": NSNull(),
                    "bio": NSNull(),
                    "websiteUrl": NSNull(),
                    "createdAt": "2026-01-01T00:00:00.000Z"
                ],
                "recentComments": []
            ]
            return (makeHTTPResponse(), try encodeJSON(body))
        }

        do {
            _ = try await makeContractClient().fetchUserProfile(userId: Self.profileID)
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            #expect(error == .invalidResponse)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
