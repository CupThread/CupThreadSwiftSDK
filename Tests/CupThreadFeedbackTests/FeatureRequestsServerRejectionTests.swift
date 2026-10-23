import Foundation
import SwiftUI
import Testing
@testable import CupThreadFeedback

/// BUG-42 (issue #523): a server-side permission rejection used to latch for
/// the lifetime of `FeatureRequestsView`. The verdict now belongs to one load
/// cycle, and the placeholder offers a retry when the preflight permits the
/// request.
@Suite("FeatureRequestsView Server Rejection Recovery", .serialized)
struct FeatureRequestsServerRejectionTests {
    static let apiHost = "feature-rejection.example.com"

    /// Thread-safe fail-then-succeed sequence; the URLProtocol handler runs
    /// off the test actor.
    private final class ResponseSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var failuresRemaining: Int
        private var requests = 0

        init(failures: Int) {
            failuresRemaining = failures
        }

        func consumeFailure() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            requests += 1
            guard failuresRemaining > 0 else { return false }
            failuresRemaining -= 1
            return true
        }

        var requestCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }
    }

    private func makeConfig(allowAnonymousRoadmap: Bool = true) -> PublicAppConfig {
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

    private func makeRecoveryClient() -> FeedbackClient {
        makeClient(
            baseURL: URL(string: "https://\(Self.apiHost)")!,
            appKey: "app_testkey123456",
            authenticationProvider: { "expired-jwt" }
        )
    }

    @MainActor
    private func makeView(
        _ latch: ServerRejectionLatch,
        allowAnonymousRoadmap: Bool = true,
        preResolvedAuthentication: Bool = true
    ) -> FeatureRequestsView {
        FeatureRequestsView(
            client: makeRecoveryClient(),
            userToken: "tok",
            configOverride: makeConfig(allowAnonymousRoadmap: allowAnonymousRoadmap),
            preResolvedAuthentication: preResolvedAuthentication,
            serverRejection: latch
        )
    }

    private func rejectionBody() throws -> Data {
        try encodeJSON(["error": "Sign in required", "code": "authentication_required"])
    }

    private func stubFeatureRequests(_ sequence: ResponseSequence) {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            guard request.url?.path.hasSuffix("/feature-requests") == true else {
                return (makeHTTPResponse(), try encodeJSON([:]))
            }
            if sequence.consumeFailure() {
                return (makeHTTPResponse(status: 401), try rejectionBody())
            }
            return (makeHTTPResponse(), try encodeJSON(["requests": [], "total": 0]))
        }
    }

    private func stubVersions(_ sequence: ResponseSequence) {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            guard request.url?.path.contains("/versions/") == true else {
                return (makeHTTPResponse(), try encodeJSON([:]))
            }
            if sequence.consumeFailure() {
                return (makeHTTPResponse(status: 401), try rejectionBody())
            }
            return (makeHTTPResponse(), try encodeJSON(["versions": []]))
        }
    }

    // MARK: - Latch semantics

    @Test func beginLoadCycleDiscardsThePreviousVerdict() {
        let latch = ServerRejectionLatch()
        latch.reject()
        #expect(latch.isRejected)

        latch.beginLoadCycle()
        #expect(!latch.isRejected)
    }

    // MARK: - Load cycles re-test the server

    @Test @MainActor func transientVersionsRejectionClearsOnTheNextSuccessfulLoad() async {
        let sequence = ResponseSequence(failures: 1)
        stubVersions(sequence)
        let latch = ServerRejectionLatch()
        let view = makeView(latch)

        await view.loadVersions()
        #expect(latch.isRejected)
        #expect(view.isRoadmapPermissionBlocked)

        await view.loadVersions()
        #expect(!latch.isRejected)
        #expect(!view.isRoadmapPermissionBlocked)
        #expect(sequence.requestCount == 2)
    }

    // MARK: - Retry affordance

    @Test @MainActor func retryIsOfferedOnlyForAServerRejectionUnderAPermittedPreflight() {
        let rejected = ServerRejectionLatch()
        rejected.reject()

        let permitted = makeView(rejected)
        #expect(permitted.isRoadmapPermissionBlocked)
        #expect(permitted.canRetryServerRejection)

        let preflightDenied = makeView(
            rejected,
            allowAnonymousRoadmap: false,
            preResolvedAuthentication: false
        )
        #expect(preflightDenied.isRoadmapPermissionBlocked)
        #expect(!preflightDenied.canRetryServerRejection)

        let notRejected = makeView(ServerRejectionLatch())
        #expect(!notRejected.isRoadmapPermissionBlocked)
        #expect(!notRejected.canRetryServerRejection)
    }

    @Test @MainActor func retryRunsAFreshLoadAndClearsTheLatch() async {
        let sequence = ResponseSequence(failures: 0)
        stubFeatureRequests(sequence)
        let latch = ServerRejectionLatch()
        latch.reject()
        let view = makeView(latch)

        #expect(view.canRetryServerRejection)
        await view.permissionRetryAction?()

        #expect(!latch.isRejected)
        #expect(!view.isRoadmapPermissionBlocked)
        #expect(sequence.requestCount == 1)
    }
}
