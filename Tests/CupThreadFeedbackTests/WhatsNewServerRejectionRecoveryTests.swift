import Foundation
import SwiftUI
import Testing
@testable import CupThreadFeedback

/// BUG-42 follow-up (issue #533): `WhatsNewView` used to render a static
/// permission placeholder after one transient `401 authentication_required`,
/// with no retry, no pull-to-refresh target, and the subscribe toolbar item
/// hidden while blocked. The placeholder now offers a retry when the preflight
/// still permits access, and the retry enters the normal load path so the
/// start-of-cycle reset clears the verdict.
@Suite("WhatsNewView Server Rejection Recovery", .serialized)
struct WhatsNewServerRejectionRecoveryTests {
    static let apiHost = "whatsnew-rejection.example.com"

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

    private func makeConfig(allowAnonymousChangelog: Bool = true) -> PublicAppConfig {
        PublicAppConfig(
            appId: "app-1",
            appKey: "app_testkey123456",
            slug: "demo",
            name: "Demo",
            allowPublic: true,
            allowedPlatforms: nil,
            allowedPlatformValues: [],
            allowAnonymousRoadmap: true,
            allowAnonymousVote: true,
            allowAnonymousFeedback: true,
            allowAnonymousChangelog: allowAnonymousChangelog
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
        allowAnonymousChangelog: Bool = true,
        preResolvedAuthentication: Bool = true
    ) -> WhatsNewView {
        WhatsNewView(
            client: makeRecoveryClient(authenticated: preResolvedAuthentication),
            userToken: "tok",
            configOverride: makeConfig(allowAnonymousChangelog: allowAnonymousChangelog),
            preResolvedAuthentication: preResolvedAuthentication,
            serverRejection: latch
        )
    }

    private func rejectionBody() throws -> Data {
        try encodeJSON(["error": "Sign in required", "code": "authentication_required"])
    }

    private func stubChangelog(_ sequence: ResponseSequence) {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            guard request.url?.path.hasSuffix("/changelog") == true else {
                return (makeHTTPResponse(), try encodeJSON([:]))
            }
            if sequence.consumeFailure() {
                return (makeHTTPResponse(status: 401), try rejectionBody())
            }
            return (
                makeHTTPResponse(),
                try encodeJSON(["entries": [], "hasMore": false])
            )
        }
    }

    // MARK: - Retry affordance

    @Test @MainActor func retryIsOfferedOnlyForAServerRejectionUnderAPermittedPreflight() {
        let rejected = ServerRejectionLatch()
        rejected.rejectList()

        let permitted = makeView(rejected)
        #expect(permitted.isChangelogPermissionBlocked)
        #expect(permitted.canRetryServerRejection)
        #expect(permitted.permissionRetryAction != nil)
        #expect(viewTreeContains(permitted.body, SdkPermissionDeniedView.self))

        let preflightDenied = makeView(
            rejected,
            allowAnonymousChangelog: false,
            preResolvedAuthentication: false
        )
        #expect(preflightDenied.isChangelogPermissionBlocked)
        #expect(!preflightDenied.canRetryServerRejection)
        #expect(preflightDenied.permissionRetryAction == nil)
        #expect(viewTreeContains(preflightDenied.body, SdkPermissionDeniedView.self))

        let notRejected = makeView(ServerRejectionLatch())
        #expect(!notRejected.isChangelogPermissionBlocked)
        #expect(!notRejected.canRetryServerRejection)
        #expect(notRejected.permissionRetryAction == nil)
    }

    // MARK: - Recovery through the normal load path

    @Test @MainActor func serverRejectionRendersThePlaceholderAndRetryClearsIt() async {
        let sequence = ResponseSequence(failures: 1)
        stubChangelog(sequence)
        let latch = ServerRejectionLatch()
        let view = makeView(latch)

        await view.loadEntries()

        #expect(latch.isRejected)
        #expect(view.isChangelogPermissionBlocked)
        #expect(view.canRetryServerRejection)
        #expect(viewTreeContains(view.body, SdkPermissionDeniedView.self))
        #expect(sequence.requestCount == 1)

        // The retry starts a fresh load cycle, whose start-of-cycle reset
        // clears the latch and re-enables the subscribe entry point.
        await view.permissionRetryAction?()

        #expect(!latch.isRejected)
        #expect(!view.isChangelogPermissionBlocked)
        #expect(view.permissionRetryAction == nil)
        #expect(!viewTreeContains(view.body, SdkPermissionDeniedView.self))
        #expect(sequence.requestCount == 2)
    }

    @Test @MainActor func preflightDenialOffersNoRetryAndIssuesNoRequest() async {
        let sequence = ResponseSequence(failures: 0)
        stubChangelog(sequence)
        let latch = ServerRejectionLatch()
        latch.rejectList()
        let view = makeView(
            latch,
            allowAnonymousChangelog: false,
            preResolvedAuthentication: false
        )

        #expect(view.isChangelogPermissionBlocked)
        #expect(!view.canRetryServerRejection)
        #expect(view.permissionRetryAction == nil)

        await view.loadEntries()

        #expect(sequence.requestCount == 0)
        #expect(view.isChangelogPermissionBlocked)
    }
}
