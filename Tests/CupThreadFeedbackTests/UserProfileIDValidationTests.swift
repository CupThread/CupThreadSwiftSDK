import Foundation
import Testing
@testable import CupThreadFeedback

// Issue #411 (API-26): `fetchUserProfile(userId:)` interpolated an
// unvalidated `userId` straight into the URL path, so a blank id produced a
// futile double-slash round trip (`/api/v1/users//profile`) and a
// path-traversing id could reroute the request on the API origin while
// carrying the caller's `Authorization` header. Ids are now trimmed and
// checked against the same single-segment grammar as feature-request ids
// (API-24) before any request is built.
@Suite("UserProfileIDValidation", .serialized)
struct UserProfileIDValidationTests {
    static let apiHost = "profile-id-validation.example.com"

    static func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    @Test("fetchUserProfile rejects invalid user ids locally with no network call")
    func fetchUserProfileRejectsInvalidIDs() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            let body: [String: Any] = [
                "profile": ["clerkUserId": "user_123", "createdAt": "2026-01-01T00:00:00.000Z"],
                "publicApps": [],
                "recentComments": []
            ]
            return (makeHTTPResponse(), try encodeJSON(body))
        }

        for invalidID in [
            "", "   ", " \n\t ",
            "../admin", "user/profile", "user/../../feedback",
            "id?next=1", "id#fragment", "%2e%2e", "a b", "é",
            String(repeating: "a", count: 129)
        ] {
            await #expect(throws: FeedbackClientError.userProfileNotFound(message: nil, requestId: nil)) {
                _ = try await Self.makeAPIClient().fetchUserProfile(userId: invalidID)
            }
        }
        #expect(capture.value == nil, "An invalid id must be rejected before any request is sent")
    }

    @Test("fetchUserProfile trims a padded id and requests the trimmed path")
    func fetchUserProfileTrimsPaddedID() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            let body: [String: Any] = [
                "profile": ["clerkUserId": "user_trimmed", "createdAt": "2026-01-01T00:00:00.000Z"],
                "publicApps": [],
                "recentComments": []
            ]
            return (makeHTTPResponse(), try encodeJSON(body))
        }

        let profile = try await Self.makeAPIClient().fetchUserProfile(userId: " user_trimmed\t")

        let request = try #require(capture.value)
        #expect(request.url?.path == "/api/v1/users/user_trimmed/profile")
        #expect(profile.profile.clerkUserId == "user_trimmed")
    }

    @Test("fetchUserProfile validates the trimmed app-scoped id before the appKey lookup")
    func fetchUserProfileTrimsAppScopedIDBeforeKeying() async throws {
        // A padded app-scoped id (`u_<32-hex>`, from board/comment payloads)
        // must be trimmed before both the grammar check and the `appKey`
        // query-parameter branch (#139).
        let appScopedID = "u_" + String(repeating: "b", count: 32)
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            let body: [String: Any] = [
                "profile": ["clerkUserId": appScopedID, "createdAt": "2026-01-01T00:00:00.000Z"],
                "publicApps": [],
                "recentComments": []
            ]
            return (makeHTTPResponse(), try encodeJSON(body))
        }

        _ = try await Self.makeAPIClient().fetchUserProfile(userId: "  \(appScopedID)  ")

        let request = try #require(capture.value)
        #expect(request.url?.path == "/api/v1/users/\(appScopedID)/profile")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first { $0.name == "appKey" }?.value == "app_testkey123456")
    }

    @Test("UserProfileIDGrammar accepts real id shapes and rejects path-breaking input")
    func grammarAcceptsRealIDShapes() {
        #expect(UserProfileIDGrammar.isValid("a"))
        #expect(UserProfileIDGrammar.isValid("user_2abcXYZ"))
        #expect(UserProfileIDGrammar.isValid("fr-42_X"))
        #expect(UserProfileIDGrammar.isValid("u_" + String(repeating: "a", count: 32)))
        #expect(UserProfileIDGrammar.isValid(String(repeating: "a", count: 128)))

        #expect(!UserProfileIDGrammar.isValid(""))
        #expect(!UserProfileIDGrammar.isValid("."))
        #expect(!UserProfileIDGrammar.isValid(".."))
        #expect(!UserProfileIDGrammar.isValid("a.b"))
        #expect(!UserProfileIDGrammar.isValid("a/b"))
        #expect(!UserProfileIDGrammar.isValid("a b"))
        #expect(!UserProfileIDGrammar.isValid("é"))
        #expect(!UserProfileIDGrammar.isValid(String(repeating: "a", count: 129)))
    }
}
