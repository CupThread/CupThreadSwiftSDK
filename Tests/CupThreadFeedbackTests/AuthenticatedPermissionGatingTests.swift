import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Fixtures

private func makeLockedDownConfig(
    allowedPlatforms: [FeedbackPlatform]? = nil
) -> PublicAppConfig {
    PublicAppConfig(
        appId: "app-1",
        appKey: "app_testkey123456",
        slug: "demo",
        name: "Demo",
        allowPublic: true,
        allowedPlatforms: allowedPlatforms,
        allowedPlatformValues: [],
        allowAnonymousRoadmap: false,
        allowAnonymousVote: false,
        allowAnonymousFeedback: false,
        allowAnonymousChangelog: false
    )
}

// MARK: - Authenticated-client preflight exceptions (issue #233)

/// Hosts that wire an `authenticationProvider` are not bound by the console's
/// *anonymous*-access switches: the bearer token satisfies the UI preflight
/// and the server stays authoritative for actual 401/403 rejections. Clients
/// without a provider keep the fail-closed anonymous behavior.
@Suite("Authenticated client permission gating")
struct AuthenticatedPermissionGatingTests {
    @Test func authenticatedClientKeepsVotePillsEnabled() {
        #expect(!FeatureVoteGate.isActionDisabled(
            isOwnRequest: false,
            config: makeLockedDownConfig(),
            supportsAuthentication: true
        ))
        // Own requests stay disabled regardless of authentication.
        #expect(FeatureVoteGate.isActionDisabled(
            isOwnRequest: true,
            config: makeLockedDownConfig(),
            supportsAuthentication: true
        ))
        // The permission hint gives way to the regular toggle hint.
        #expect(FeatureVoteGate.hintKey(
            isOwnRequest: false,
            config: makeLockedDownConfig(),
            supportsAuthentication: true
        ) == "cupthread.features.vote_toggle_hint")
    }

    @Test func anonymousClientStillFailsClosedForVotePills() {
        #expect(FeatureVoteGate.isActionDisabled(
            isOwnRequest: false,
            config: makeLockedDownConfig(),
            supportsAuthentication: false
        ))
        #expect(FeatureVoteGate.hintKey(
            isOwnRequest: false,
            config: makeLockedDownConfig(),
            supportsAuthentication: false
        ) == "cupthread.permission.vote_hint")
    }

    @Test func authenticatedClientPassesComposePreflight() {
        #expect(SdkSubmissionDenial.forFeedback(
            config: makeLockedDownConfig(),
            platform: .ios,
            supportsAuthentication: true
        ) == .none)
        #expect(SdkSubmissionDenial.forFeatureRequest(
            config: makeLockedDownConfig(),
            supportsAuthentication: true
        ) == .none)
    }

    @Test func platformAllowListStillAppliesToAuthenticatedClient() {
        let config = makeLockedDownConfig(allowedPlatforms: [.macos])
        #expect(SdkSubmissionDenial.forFeedback(
            config: config,
            platform: .ios,
            supportsAuthentication: true
        ) == .platformNotAllowed)
        #expect(SdkSubmissionDenial.forFeedback(
            config: config,
            platform: .macos,
            supportsAuthentication: true
        ) == .none)
    }

    @Test func anonymousClientStillDeniedForCompose() {
        #expect(SdkSubmissionDenial.forFeedback(
            config: makeLockedDownConfig(),
            platform: .ios,
            supportsAuthentication: false
        ) == .anonymousFeedbackDisabled)
        #expect(SdkSubmissionDenial.forFeatureRequest(
            config: makeLockedDownConfig(),
            supportsAuthentication: false
        ) == .anonymousFeedbackDisabled)
    }

    @Test func authenticatedClientKeepsComposeAffordanceUnderDeniedConfig() {
        #expect(FeatureRequestComposeDismissalAffordance.resolve(
            config: makeLockedDownConfig(),
            supportsAuthentication: true
        ) == .guardedCancel)
        #expect(FeatureRequestComposeDismissalAffordance.resolve(
            config: makeLockedDownConfig(),
            supportsAuthentication: false
        ) == .close)
    }

    @Test func authenticatedClientLoadPlansStillLoad() {
        #expect(roadmapLoadPlan(config: makeLockedDownConfig(), supportsAuthentication: true) == .load)
        #expect(changelogLoadPlan(config: makeLockedDownConfig(), supportsAuthentication: true) == .load)
    }

    @Test func anonymousClientLoadPlansStillSkip() {
        #expect(roadmapLoadPlan(config: makeLockedDownConfig(), supportsAuthentication: false) == .skip)
        #expect(changelogLoadPlan(config: makeLockedDownConfig(), supportsAuthentication: false) == .skip)
    }

    @Test func nilConfigFailsOpenRegardlessOfAuthentication() {
        #expect(roadmapLoadPlan(config: nil, supportsAuthentication: true) == .load)
        #expect(roadmapLoadPlan(config: nil, supportsAuthentication: false) == .load)
        #expect(changelogLoadPlan(config: nil, supportsAuthentication: true) == .load)
        #expect(changelogLoadPlan(config: nil, supportsAuthentication: false) == .load)
        #expect(SdkSubmissionDenial.forFeedback(config: nil, platform: .ios, supportsAuthentication: true) == .none)
        #expect(SdkSubmissionDenial.forFeatureRequest(config: nil, supportsAuthentication: true) == .none)
    }
}

// MARK: - Network-level preflight bypass (issue #233)

@Suite("Authenticated client permission fetching", .serialized)
struct AuthenticatedPermissionFetchingTests {
    static let apiHost = "permission-gate-auth.example.com"

    private final class RequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(path: String, authorization: String?)] = []

        func record(_ request: URLRequest) {
            lock.lock()
            defer { lock.unlock() }
            entries.append((
                request.url?.path ?? "",
                request.value(forHTTPHeaderField: "Authorization")
            ))
        }

        var recorded: [String] {
            lock.lock()
            defer { lock.unlock() }
            return entries.map(\.path)
        }

        var authorizations: [String?] {
            lock.lock()
            defer { lock.unlock() }
            return entries.map(\.authorization)
        }
    }

    @Test func disallowedRoadmapStillFetchesForAuthenticatedClient() async throws {
        let counter = RequestCounter()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            counter.record(request)
            if request.url?.path.contains("/columns/") == true {
                let column: [String: Any] = [
                    "id": "c1",
                    "appId": "app-1",
                    "name": "Backlog",
                    "slug": "backlog",
                    "position": 0,
                    "isVisible": true,
                    "isSystem": true,
                    "kind": "pending_review",
                    "createdAt": "2026-01-01T00:00:00.000Z",
                    "updatedAt": "2026-01-01T00:00:00.000Z"
                ]
                return (makeHTTPResponse(), try encodeJSON(["columns": [column]]))
            }
            return (makeHTTPResponse(), try encodeJSON(["requests": [], "total": 0]))
        }
        let client = makeClient(
            baseURL: URL(string: "https://\(Self.apiHost)")!,
            authenticationProvider: { "signed-in-jwt" }
        )
        let result = try await loadRoadmapGroups(
            client: client,
            userToken: "tok",
            query: nil,
            config: makeLockedDownConfig()
        )
        let groups = try #require(result)
        #expect(groups.count == 1)
        #expect(counter.recorded.contains { $0.contains("/columns/") })
        #expect(counter.recorded.contains { $0.contains("/feature-requests") })
        #expect(counter.authorizations.allSatisfy { $0 == "Bearer signed-in-jwt" })
    }

    @Test func disallowedChangelogStillFetchesForAuthenticatedClient() async throws {
        let counter = RequestCounter()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            counter.record(request)
            let entry: [String: Any] = [
                "id": "e-perm-auth-1",
                "title": "Version 1.0",
                "body": "First release",
                "versionLabel": "1.0.0",
                "publishedAt": "2026-01-01T00:00:00.000Z",
                "linkedRequests": []
            ]
            return (makeHTTPResponse(), try encodeJSON(["entries": [entry]]))
        }
        let client = makeClient(
            baseURL: URL(string: "https://\(Self.apiHost)")!,
            authenticationProvider: { "signed-in-jwt" }
        )
        let result = try await loadChangelogEntries(
            client: client,
            config: makeLockedDownConfig()
        )
        let entries = try #require(result)
        #expect(entries.count == 1)
        #expect(entries.first?.id == "e-perm-auth-1")
        #expect(counter.recorded.contains { $0.contains("/changelog") })
        #expect(counter.authorizations.allSatisfy { $0 == "Bearer signed-in-jwt" })
    }
}
