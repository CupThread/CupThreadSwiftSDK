import Foundation
import SwiftUI
import Testing
@testable import CupThreadFeedback

/// CONC-15 (issue #408) regression tests: the version-filter load used to
/// evaluate the roadmap permission verdict before authentication resolved,
/// so on private roadmaps (`allowsAnonymousRoadmap == false`) it returned
/// immediately and depended entirely on the concurrent search task to flip
/// `isAuthenticated` and restart it through the `.task(id:)` key. A search
/// task that was debounced, throttled, or failed before resolving
/// authentication left the filter permanently disabled.
///
/// Two layers pin the contract:
///
/// - `resolveRoadmapAccess` truth tables: authentication resolves *before*
///   the permission verdict is evaluated, and anonymous boards keep failing
///   open without a provider.
/// - `loadVersions` driven end to end and observed through the stubbed
///   endpoint: on a private roadmap a versions request leaving the client
///   proves the verdict passed after in-load resolution (pre-fix, the
///   fail-closed pre-resolution default denied it before any network
///   traffic). The request log is the observable because a view outside a
///   SwiftUI hierarchy cannot persist `@State` writes.
@Suite("FeatureRequestsView Version Filter Load Lifecycle", .serialized)
struct FeatureRequestsVersionFilterTests {
    static let apiHost = "version-lifecycle.example.com"

    // MARK: - Helpers

    /// Thread-safe request log; the URLProtocol handler runs off the test actor.
    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [String] = []
        func record(path: String) {
            lock.lock()
            defer { lock.unlock() }
            requests.append(path)
        }
        var paths: [String] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }
    }

    private func makeConfig(allowAnonymousRoadmap: Bool) -> PublicAppConfig {
        PublicAppConfig(
            appId: "app-1",
            appKey: "app_testkey123456",
            slug: "demo",
            name: "Demo",
            allowPublic: true,
            allowedPlatforms: nil,
            allowedPlatformValues: [],
            allowAnonymousRoadmap: allowAnonymousRoadmap,
            allowAnonymousVote: true,
            allowAnonymousFeedback: true,
            allowAnonymousChangelog: true
        )
    }

    private func makeAccessClient(authenticationToken: String?) -> FeedbackClient {
        let provider: (@Sendable () async -> String?)?
        if let authenticationToken {
            provider = { authenticationToken }
        } else {
            provider = nil
        }
        return makeClient(
            baseURL: URL(string: "https://\(Self.apiHost)")!,
            appKey: "app_testkey123456",
            authenticationProvider: provider
        )
    }

    @MainActor
    private func makeView(
        allowAnonymousRoadmap: Bool,
        authenticationToken: String?
    ) -> FeatureRequestsView {
        FeatureRequestsView(
            client: makeAccessClient(authenticationToken: authenticationToken),
            userToken: "test_token_123",
            configOverride: makeConfig(allowAnonymousRoadmap: allowAnonymousRoadmap)
        )
    }

    private func stubVersionsEndpoint() -> RequestLog {
        let log = RequestLog()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            log.record(path: request.url?.path ?? "")
            let body: [String: Any] = ["versions": [
                ["id": "ver-1", "appId": "app-1", "label": "2.1", "position": 0,
                 "released": true, "releasedAt": NSNull(), "description": NSNull(),
                 "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-01-01T00:00:00.000Z"],
                ["id": "ver-2", "appId": "app-1", "label": "2.2", "position": 1,
                 "released": false, "releasedAt": NSNull(), "description": NSNull(),
                 "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-01-01T00:00:00.000Z"]
            ]]
            return (makeHTTPResponse(status: 200), try JSONSerialization.data(withJSONObject: body))
        }
        return log
    }

    // MARK: - resolveRoadmapAccess: resolution precedes the verdict

    @Test @MainActor func resolveRoadmapAccessEvaluatesVerdictAfterAuthentication() async {
        let privateConfig = makeConfig(allowAnonymousRoadmap: false)
        let anonymousConfig = makeConfig(allowAnonymousRoadmap: true)

        // Private roadmap, no identity: denied, exactly as before.
        let denied = await FeatureRequestsView.resolveRoadmapAccess(
            client: makeAccessClient(authenticationToken: nil),
            config: privateConfig
        )
        #expect(!denied.supportsAuthentication)
        #expect(!denied.isPermitted)

        // Private roadmap, signed-in identity: the verdict sees the resolved
        // authentication and permits the load — the pre-CONC-15 ordering
        // evaluated the fail-closed default instead and denied here.
        let permitted = await FeatureRequestsView.resolveRoadmapAccess(
            client: makeAccessClient(authenticationToken: "valid_jwt_token"),
            config: privateConfig
        )
        #expect(permitted.supportsAuthentication)
        #expect(permitted.isPermitted)

        // Anonymous roadmaps never depend on the resolution outcome...
        let anonymous = await FeatureRequestsView.resolveRoadmapAccess(
            client: makeAccessClient(authenticationToken: nil),
            config: anonymousConfig
        )
        #expect(!anonymous.supportsAuthentication)
        #expect(anonymous.isPermitted)

        // ...and a nil config fails open (the server stays authoritative).
        let failOpen = await FeatureRequestsView.resolveRoadmapAccess(
            client: makeAccessClient(authenticationToken: nil),
            config: nil
        )
        #expect(!failOpen.supportsAuthentication)
        #expect(failOpen.isPermitted)
    }

    // MARK: - loadVersions: end-to-end load lifecycle

    @Test @MainActor func loadVersionsResolvesAuthenticationOnPrivateRoadmap() async {
        let log = stubVersionsEndpoint()
        let view = makeView(allowAnonymousRoadmap: false, authenticationToken: "valid_jwt_token")

        await view.loadVersions()

        // A versions request left the client although the roadmap is private:
        // the fetch itself proves the verdict was evaluated after
        // authentication resolved, with no concurrent search task involved.
        #expect(log.paths == ["/api/v1/public/versions/app_testkey123456"])
    }

    @Test @MainActor func loadVersionsWithoutAuthenticationOnPrivateRoadmapNeverFetches() async {
        let log = stubVersionsEndpoint()
        let view = makeView(allowAnonymousRoadmap: false, authenticationToken: nil)

        await view.loadVersions()

        // The denial verdict still short-circuits before any network traffic.
        #expect(log.paths.isEmpty)
    }

    @Test @MainActor func loadVersionsOnAnonymousRoadmapKeepsLoadingWithoutAuthentication() async {
        let log = stubVersionsEndpoint()
        let view = makeView(allowAnonymousRoadmap: true, authenticationToken: nil)

        await view.loadVersions()

        // Anonymous boards are unaffected by the added resolution step.
        #expect(log.paths == ["/api/v1/public/versions/app_testkey123456"])
    }
}
