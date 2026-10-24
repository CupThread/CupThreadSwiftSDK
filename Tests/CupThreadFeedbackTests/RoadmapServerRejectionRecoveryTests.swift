import Foundation
import SwiftUI
import Testing
@testable import CupThreadFeedback

/// BUG-42 follow-up (issue #533): `RoadmapBoardView` used to render a static
/// permission placeholder after one transient `401 authentication_required`,
/// with no in-surface way to start a new load cycle. The placeholder now offers
/// a retry when the preflight still permits access, and the retry enters the
/// normal load path so the start-of-cycle reset clears the verdict.
@Suite("RoadmapBoardView Server Rejection Recovery", .serialized)
struct RoadmapServerRejectionRecoveryTests {
    static let apiHost = "roadmap-rejection.example.com"

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

    private func makeRecoveryClient(authenticated: Bool = true) -> FeedbackClient {
        makeClient(
            baseURL: URL(string: "https://\(Self.apiHost)")!,
            appKey: "app_testkey123456",
            authenticationProvider: { authenticated ? "expired-jwt" : nil }
        )
    }

    @MainActor
    private func makeView(
        _ latch: ServerRejectionLatch,
        allowAnonymousRoadmap: Bool = true,
        preResolvedAuthentication: Bool = true
    ) -> RoadmapBoardView {
        RoadmapBoardView(
            client: makeRecoveryClient(authenticated: preResolvedAuthentication),
            userToken: "tok",
            initialGroups: nil,
            configOverride: makeConfig(allowAnonymousRoadmap: allowAnonymousRoadmap),
            preResolvedAuthentication: preResolvedAuthentication,
            serverRejection: latch
        )
    }

    private func rejectionBody() throws -> Data {
        try encodeJSON(["error": "Sign in required", "code": "authentication_required"])
    }

    private func stubRoadmap(_ sequence: ResponseSequence) {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            let path = request.url?.path ?? ""
            let isColumns = path.contains("/columns/")
            let isRequests = path.hasSuffix("/feature-requests")
            guard isColumns || isRequests else {
                return (makeHTTPResponse(), try encodeJSON([:]))
            }
            if sequence.consumeFailure() {
                return (makeHTTPResponse(status: 401), try rejectionBody())
            }
            if isColumns {
                return (makeHTTPResponse(), try encodeJSON(["columns": []]))
            }
            return (makeHTTPResponse(), try encodeJSON(["requests": [], "total": 0]))
        }
    }

    // MARK: - Retry affordance

    @Test @MainActor func retryIsOfferedOnlyForAServerRejectionUnderAPermittedPreflight() {
        let rejected = ServerRejectionLatch()
        rejected.rejectList()

        let permitted = makeView(rejected)
        #expect(permitted.isRoadmapPermissionBlocked)
        #expect(permitted.canRetryServerRejection)
        #expect(permitted.permissionRetryAction != nil)
        #expect(viewTreeContains(permitted.body, SdkPermissionDeniedView.self))

        let preflightDenied = makeView(
            rejected,
            allowAnonymousRoadmap: false,
            preResolvedAuthentication: false
        )
        #expect(preflightDenied.isRoadmapPermissionBlocked)
        #expect(!preflightDenied.canRetryServerRejection)
        #expect(preflightDenied.permissionRetryAction == nil)
        #expect(viewTreeContains(preflightDenied.body, SdkPermissionDeniedView.self))

        let notRejected = makeView(ServerRejectionLatch())
        #expect(!notRejected.isRoadmapPermissionBlocked)
        #expect(!notRejected.canRetryServerRejection)
        #expect(notRejected.permissionRetryAction == nil)
    }

    // MARK: - Recovery through the normal load path

    @Test @MainActor func serverRejectionRendersThePlaceholderAndRetryClearsIt() async {
        let sequence = ResponseSequence(failures: 0)
        stubRoadmap(sequence)
        let latch = ServerRejectionLatch()
        let view = makeView(latch)

        // The 401 is already mapped to `authenticationRequired` by the client;
        // feed that verdict to the failure branch directly because
        // `loadGeneration` does not advance outside a SwiftUI hierarchy.
        await view.handleLoadFailureForTesting(FeedbackClientError.authenticationRequired)

        #expect(latch.isRejected)
        #expect(view.isRoadmapPermissionBlocked)
        #expect(view.canRetryServerRejection)
        #expect(viewTreeContains(view.body, SdkPermissionDeniedView.self))
        #expect(sequence.requestCount == 0)

        // The retry starts a fresh load cycle, whose start-of-cycle reset
        // clears the latch before the request lands.
        await view.permissionRetryAction?()

        #expect(!latch.isRejected)
        #expect(!view.isRoadmapPermissionBlocked)
        #expect(view.permissionRetryAction == nil)
        #expect(!viewTreeContains(view.body, SdkPermissionDeniedView.self))
        #expect(sequence.requestCount == 2)
    }

    @Test @MainActor func preflightDenialOffersNoRetryAndIssuesNoRequest() async {
        let sequence = ResponseSequence(failures: 0)
        stubRoadmap(sequence)
        let latch = ServerRejectionLatch()
        latch.rejectList()
        let view = makeView(
            latch,
            allowAnonymousRoadmap: false,
            preResolvedAuthentication: false
        )

        #expect(view.isRoadmapPermissionBlocked)
        #expect(!view.canRetryServerRejection)
        #expect(view.permissionRetryAction == nil)

        await view.loadForTesting()

        #expect(sequence.requestCount == 0)
        #expect(view.isRoadmapPermissionBlocked)
    }
}
