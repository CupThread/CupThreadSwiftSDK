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
//
// Issue #512 (PRIV-06, SaaS#1322): the unauthenticated profile endpoint
// resolves app-scoped pseudonyms (`u_` + 32 lowercase hex) only. Every other
// identifier — raw Clerk ids included — now answers the anonymous
// placeholder (HTTP 200, `displayName: null`, empty collections), which is
// indistinguishable from a user who opted out. The SDK rejects those shapes
// locally so a caller gets the documented not-found error instead of an
// empty profile presented as data.
@Suite("UserProfileIDValidation", .serialized)
struct UserProfileIDValidationTests {
    static let apiHost = "profile-id-validation.example.com"

    static let validPseudonym = "u_" + String(repeating: "a", count: 32)

    static func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    static func makeProfileBody(identifier: String) -> [String: Any] {
        [
            "profile": ["clerkUserId": identifier, "createdAt": "2026-01-01T00:00:00.000Z"],
            "publicApps": [],
            "recentComments": []
        ]
    }

    @Test("fetchUserProfile rejects invalid user ids locally with no network call")
    func fetchUserProfileRejectsInvalidIDs() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(Self.makeProfileBody(identifier: Self.validPseudonym)))
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

    @Test("fetchUserProfile rejects non-pseudonym identifiers locally with no network call")
    func fetchUserProfileRejectsNonPseudonymIDs() async throws {
        // Every shape below is a well-formed single URL path segment, so the
        // API-26 grammar accepts it — but the profile endpoint no longer
        // resolves it (PRIV-06, SaaS#1322), so dispatching would only earn a
        // silent anonymous placeholder.
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(Self.makeProfileBody(identifier: Self.validPseudonym)))
        }

        for rejectedID in [
            // Raw Clerk ids: the legacy `/u/` bookmark shape.
            "user_2abcXYZ", "user_2abcDEF123",
            // `u_` prefixed, but not the resolved shape.
            "u_", "u_zz", "u_abc",
            "u_" + String(repeating: "a", count: 31),
            "u_" + String(repeating: "a", count: 33),
            "u_" + String(repeating: "A", count: 32),
            "u_" + String(repeating: "g", count: 32),
            "U_" + String(repeating: "a", count: 32),
            // Other single-segment shapes a host might pass by mistake.
            "fr-42_X", "a"
        ] {
            await #expect(throws: FeedbackClientError.userProfileNotFound(message: nil, requestId: nil)) {
                _ = try await Self.makeAPIClient().fetchUserProfile(userId: rejectedID)
            }
        }
        #expect(capture.value == nil, "A non-pseudonym id must be rejected before any request is sent")
    }

    @Test("fetchUserProfile trims a padded pseudonym and requests the trimmed path")
    func fetchUserProfileTrimsPaddedID() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(Self.makeProfileBody(identifier: Self.validPseudonym)))
        }

        let profile = try await Self.makeAPIClient().fetchUserProfile(userId: " \(Self.validPseudonym)\t")

        let request = try #require(capture.value)
        #expect(request.url?.path == "/api/v1/users/\(Self.validPseudonym)/profile")
        #expect(profile.profile.clerkUserId == Self.validPseudonym)
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
            return (makeHTTPResponse(), try encodeJSON(Self.makeProfileBody(identifier: appScopedID)))
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

    @Test("UserProfileIDGrammar.isPseudonym accepts only the resolved pseudonym shape")
    func grammarRecognizesPseudonyms() {
        // The server's PUBLIC_USER_ID_RE is `^u_[0-9a-f]{32}$`.
        #expect(UserProfileIDGrammar.isPseudonym("u_" + String(repeating: "0", count: 32)))
        #expect(UserProfileIDGrammar.isPseudonym("u_" + String(repeating: "f", count: 32)))
        #expect(UserProfileIDGrammar.isPseudonym("u_0123456789abcdef0123456789abcdef"))
        #expect(UserProfileIDGrammar.isPseudonym(Self.validPseudonym))

        #expect(!UserProfileIDGrammar.isPseudonym(""))
        #expect(!UserProfileIDGrammar.isPseudonym("u_"))
        #expect(!UserProfileIDGrammar.isPseudonym("u_abc"))
        #expect(!UserProfileIDGrammar.isPseudonym("u_" + String(repeating: "a", count: 31)))
        #expect(!UserProfileIDGrammar.isPseudonym("u_" + String(repeating: "a", count: 33)))
        // Uppercase hex is not a minted pseudonym, and the server rejects it.
        #expect(!UserProfileIDGrammar.isPseudonym("u_" + String(repeating: "A", count: 32)))
        #expect(!UserProfileIDGrammar.isPseudonym("u_" + String(repeating: "g", count: 32)))
        #expect(!UserProfileIDGrammar.isPseudonym("U_" + String(repeating: "a", count: 32)))
        // Raw Clerk ids and other path-safe shapes never resolve here.
        #expect(!UserProfileIDGrammar.isPseudonym("user_2abcXYZ"))
        #expect(!UserProfileIDGrammar.isPseudonym("fr-42_X"))
        #expect(!UserProfileIDGrammar.isPseudonym("a"))
    }
}
