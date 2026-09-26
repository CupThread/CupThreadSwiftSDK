import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Fixtures

private func makePermissionConfig(
    allowPublic: Bool = true,
    allowedPlatforms: [FeedbackPlatform]? = nil,
    allowedPlatformValues: [String] = [],
    allowAnonymousRoadmap: Bool = true,
    allowAnonymousVote: Bool = true,
    allowAnonymousFeedback: Bool = true,
    allowAnonymousChangelog: Bool = true
) -> PublicAppConfig {
    PublicAppConfig(
        appId: "app-1",
        appKey: "app_testkey123456",
        slug: "demo",
        name: "Demo",
        allowPublic: allowPublic,
        allowedPlatforms: allowedPlatforms,
        allowedPlatformValues: allowedPlatformValues,
        allowAnonymousRoadmap: allowAnonymousRoadmap,
        allowAnonymousVote: allowAnonymousVote,
        allowAnonymousFeedback: allowAnonymousFeedback,
        allowAnonymousChangelog: allowAnonymousChangelog
    )
}

// MARK: - Predicates (issue #34 requirement 1)

@Suite("Permission predicates")
struct PermissionPredicateTests {
    @Test(arguments: [true, false])
    func allowsAnonymousVoteMirrorsFlag(enabled: Bool) {
        let config = makePermissionConfig(allowAnonymousVote: enabled)
        #expect(config.allowsAnonymousVote == enabled)
        #expect(config.allowAnonymousVote == enabled)
    }

    @Test(arguments: [true, false])
    func allowsAnonymousFeedbackMirrorsFlag(enabled: Bool) {
        let config = makePermissionConfig(allowAnonymousFeedback: enabled)
        #expect(config.allowsAnonymousFeedback == enabled)
    }

    @Test(arguments: [true, false])
    func allowsAnonymousChangelogMirrorsFlag(enabled: Bool) {
        let config = makePermissionConfig(allowAnonymousChangelog: enabled)
        #expect(config.allowsAnonymousChangelog == enabled)
        #expect(config.allowAnonymousChangelog == enabled)
    }

    @Test func allowsAnonymousRoadmapRequiresPublicAndAnonymous() {
        #expect(makePermissionConfig(allowPublic: true, allowAnonymousRoadmap: true).allowsAnonymousRoadmap)
        #expect(!makePermissionConfig(allowPublic: true, allowAnonymousRoadmap: false).allowsAnonymousRoadmap)
        #expect(!makePermissionConfig(allowPublic: false, allowAnonymousRoadmap: true).allowsAnonymousRoadmap)
        #expect(!makePermissionConfig(allowPublic: false, allowAnonymousRoadmap: false).allowsAnonymousRoadmap)
    }

    @Test func allowsAnonymousVoteRequiresPublicAndAnonymous() {
        #expect(makePermissionConfig(allowPublic: true, allowAnonymousVote: true).allowsAnonymousVote)
        #expect(!makePermissionConfig(allowPublic: true, allowAnonymousVote: false).allowsAnonymousVote)
        #expect(!makePermissionConfig(allowPublic: false, allowAnonymousVote: true).allowsAnonymousVote)
        #expect(!makePermissionConfig(allowPublic: false, allowAnonymousVote: false).allowsAnonymousVote)
    }

    @Test func allowsAnonymousFeedbackRequiresPublicAndAnonymous() {
        #expect(makePermissionConfig(allowPublic: true, allowAnonymousFeedback: true).allowsAnonymousFeedback)
        #expect(!makePermissionConfig(allowPublic: true, allowAnonymousFeedback: false).allowsAnonymousFeedback)
        #expect(!makePermissionConfig(allowPublic: false, allowAnonymousFeedback: true).allowsAnonymousFeedback)
        #expect(!makePermissionConfig(allowPublic: false, allowAnonymousFeedback: false).allowsAnonymousFeedback)
    }

    @Test func emptyPlatformAllowListIsUnrestricted() {
        let config = makePermissionConfig(allowedPlatforms: [], allowedPlatformValues: [])
        #expect(config.allows(platform: .ios))
        #expect(config.allows(platform: .macos))
        #expect(config.allows(platform: .android))
        #expect(config.allows(platform: .universal))
    }

    @Test func nonEmptyPlatformAllowListAdmitsOnlyListedPlatforms() {
        let config = makePermissionConfig(allowedPlatforms: [.ios, .macos])
        #expect(config.allows(platform: .ios))
        #expect(config.allows(platform: .macos))
        #expect(!config.allows(platform: .android))
        #expect(!config.allows(platform: .universal))
    }

    @Test func unknownOnlyPlatformAllowListClosesTheGate() {
        // A console version that ships platforms this SDK does not know still
        // produces a non-empty raw list; the server would reject us, so the
        // preflight stays closed.
        let config = makePermissionConfig(
            allowedPlatforms: nil,
            allowedPlatformValues: ["console"]
        )
        #expect(config.allowedPlatforms.isEmpty)
        #expect(!config.allowedPlatformValues.isEmpty)
        #expect(!config.allows(platform: .ios))
        #expect(!config.allows(platform: .macos))
    }
}

// MARK: - Extracted view logic (issue #34 requirement 3)

@Suite("Permission view gating")
struct PermissionViewGatingTests {
    @Test func voteActionDisabledWhenAnonymousVotingIsOff() {
        let denied = makePermissionConfig(allowAnonymousVote: false)
        #expect(FeatureVoteGate.isActionDisabled(isOwnRequest: false, config: denied))
        #expect(FeatureVoteGate.isActionDisabled(isOwnRequest: true, config: denied))
        #expect(FeatureVoteGate.hintKey(isOwnRequest: false, config: denied) == "cupthread.permission.vote_hint")
        #expect(FeatureVoteGate.hintKey(isOwnRequest: true, config: denied) == "cupthread.features.vote_own_hint")
    }

    @Test func voteActionEnabledWhenAnonymousVotingIsOnUnlessOwnRequest() {
        let allowed = makePermissionConfig(allowAnonymousVote: true)
        #expect(!FeatureVoteGate.isActionDisabled(isOwnRequest: false, config: allowed))
        #expect(FeatureVoteGate.isActionDisabled(isOwnRequest: true, config: allowed))
        #expect(FeatureVoteGate.hintKey(isOwnRequest: false, config: allowed) == "cupthread.features.vote_toggle_hint")
    }

    @Test func nilConfigFailsOpenForVoteGating() {
        #expect(!FeatureVoteGate.isActionDisabled(isOwnRequest: false, config: nil))
        #expect(FeatureVoteGate.isActionDisabled(isOwnRequest: true, config: nil))
        #expect(FeatureVoteGate.hintKey(isOwnRequest: false, config: nil) == "cupthread.features.vote_toggle_hint")
    }

    @Test func feedbackDenialCoversAnonymousAndPlatform() {
        #expect(SdkSubmissionDenial.forFeedback(config: nil, platform: .ios) == .none)
        #expect(
            SdkSubmissionDenial.forFeedback(
                config: makePermissionConfig(allowAnonymousFeedback: false),
                platform: .ios
            ) == .anonymousFeedbackDisabled
        )
        #expect(
            SdkSubmissionDenial.forFeedback(
                config: makePermissionConfig(allowedPlatforms: [.macos]),
                platform: .ios
            ) == .platformNotAllowed
        )
        #expect(
            SdkSubmissionDenial.forFeedback(
                config: makePermissionConfig(allowedPlatforms: [.ios]),
                platform: .ios
            ) == .none
        )
    }

    @Test func featureRequestDenialIgnoresPlatformAllowList() {
        #expect(SdkSubmissionDenial.forFeatureRequest(config: nil) == .none)
        #expect(
            SdkSubmissionDenial.forFeatureRequest(
                config: makePermissionConfig(allowAnonymousFeedback: false)
            ) == .anonymousFeedbackDisabled
        )
        #expect(
            SdkSubmissionDenial.forFeatureRequest(
                config: makePermissionConfig(allowedPlatforms: [.macos])
            ) == .none
        )
    }

    @Test func voteActionDisabledWhenAppIsNotPublic() {
        let privateApp = makePermissionConfig(allowPublic: false, allowAnonymousVote: true)
        #expect(FeatureVoteGate.isActionDisabled(isOwnRequest: false, config: privateApp))
        #expect(FeatureVoteGate.isActionDisabled(isOwnRequest: true, config: privateApp))
        #expect(FeatureVoteGate.hintKey(isOwnRequest: false, config: privateApp) == "cupthread.permission.vote_hint")
    }

    @Test func feedbackAndFeatureRequestDenialWhenAppIsNotPublic() {
        let privateApp = makePermissionConfig(allowPublic: false, allowAnonymousFeedback: true)
        #expect(
            SdkSubmissionDenial.forFeedback(config: privateApp, platform: .ios) == .anonymousFeedbackDisabled
        )
        #expect(
            SdkSubmissionDenial.forFeatureRequest(config: privateApp) == .anonymousFeedbackDisabled
        )
    }

    @Test func roadmapLoadPlanSkipsWhenAnonymousRoadmapIsOff() {
        #expect(roadmapLoadPlan(config: nil) == .load)
        #expect(roadmapLoadPlan(config: makePermissionConfig(allowAnonymousRoadmap: true)) == .load)
        #expect(roadmapLoadPlan(config: makePermissionConfig(allowAnonymousRoadmap: false)) == .skip)
        #expect(roadmapLoadPlan(config: makePermissionConfig(allowPublic: false)) == .skip)
    }

    @Test func changelogLoadPlanSkipsWhenAnonymousChangelogIsOff() {
        #expect(changelogLoadPlan(config: nil) == .load)
        #expect(changelogLoadPlan(config: makePermissionConfig(allowAnonymousChangelog: true)) == .load)
        #expect(changelogLoadPlan(config: makePermissionConfig(allowAnonymousChangelog: false)) == .skip)
    }
}

// MARK: - Client error mapping + roadmap request suppression (issue #34 requirements 2 & 3)

@Suite("Permission error mapping", .serialized)
struct PermissionErrorMappingTests {
    static let apiHost = "permission-gate.example.com"

    static func makeAPIClient() -> FeedbackClient {
        makeClient(baseURL: URL(string: "https://\(apiHost)")!)
    }

    private final class RequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []

        func record(_ path: String) {
            lock.lock()
            defer { lock.unlock() }
            paths.append(path)
        }

        var recorded: [String] {
            lock.lock()
            defer { lock.unlock() }
            return paths
        }
    }

    @Test func toggleVoteMaps401ToAuthenticationRequired() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 401, headers: ["X-Request-Id": "req-vote-401"]),
                try encodeJSON(["error": "Sign in required"])
            )
        }
        do {
            _ = try await Self.makeAPIClient().toggleVote(featureRequestId: "fr-1", userToken: "tok")
            Issue.record("Expected authenticationRequired")
        } catch let error as FeedbackClientError {
            #expect(error == .authenticationRequired)
        }
    }

    @Test func toggleVoteMaps403ToForbidden() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 403, headers: ["X-Request-Id": "req-vote-403"]),
                try encodeJSON(["error": "Anonymous voting disabled"])
            )
        }
        do {
            _ = try await Self.makeAPIClient().toggleVote(featureRequestId: "fr-1", userToken: "tok")
            Issue.record("Expected forbidden")
        } catch let error as FeedbackClientError {
            guard case .forbidden(let message, let requestId) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(message == "Anonymous voting disabled")
            #expect(requestId == "req-vote-403")
            #expect(error.responseBody == nil)
            #expect(error.errorDescription?.contains("Anonymous voting") != true)
        }
    }

    @Test func submitFeedbackMaps403ToForbidden() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 403),
                try encodeJSON(["error": "Anonymous feedback disabled"])
            )
        }
        do {
            _ = try await Self.makeAPIClient().submit(
                FeedbackDraft(title: "Title", description: "Long enough", platform: .ios)
            )
            Issue.record("Expected forbidden")
        } catch let error as FeedbackClientError {
            guard case .forbidden = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    @Test func submitFeatureRequestMaps401ToAuthenticationRequired() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 401), try encodeJSON(["error": "Sign in required"]))
        }
        do {
            _ = try await Self.makeAPIClient().submitFeatureRequest(
                FeatureRequestDraft(title: "Title", description: "Long enough"),
                userToken: "tok"
            )
            Issue.record("Expected authenticationRequired")
        } catch let error as FeedbackClientError {
            #expect(error == .authenticationRequired)
        }
    }

    @Test func fetchColumnsMaps403ToForbidden() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 403), try encodeJSON(["error": "Roadmap is private"]))
        }
        do {
            _ = try await Self.makeAPIClient().fetchColumns()
            Issue.record("Expected forbidden")
        } catch let error as FeedbackClientError {
            guard case .forbidden = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    @Test func fetchVersionsDoesNotMap403ToForbidden() async throws {
        // Versions is not a permission-gated intake endpoint — a 403 stays
        // unexpectedStatus so we do not over-classify unrelated failures.
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 403), try encodeJSON(["error": "nope"]))
        }
        do {
            _ = try await Self.makeAPIClient().fetchVersions()
            Issue.record("Expected unexpectedStatus")
        } catch let error as FeedbackClientError {
            guard case .unexpectedStatus(let code, let message, _) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(code == 403)
            #expect(message == "nope")
        }
    }

    @Test func disallowedRoadmapMakesNoBoardRequests() async throws {
        let counter = RequestCounter()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            counter.record(request.url?.path ?? "")
            return (makeHTTPResponse(), Data("{}".utf8))
        }
        let result = try await loadRoadmapGroups(
            client: Self.makeAPIClient(),
            userToken: "tok",
            query: nil,
            config: makePermissionConfig(allowAnonymousRoadmap: false)
        )
        #expect(result == nil)
        #expect(counter.recorded.isEmpty)
    }

    @Test func allowedRoadmapFetchesColumnsAndRequests() async throws {
        let counter = RequestCounter()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            let path = request.url?.path ?? ""
            counter.record(path)
            if path.contains("/columns/") {
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
        let result = try await loadRoadmapGroups(
            client: Self.makeAPIClient(),
            userToken: "tok",
            query: nil,
            config: makePermissionConfig(allowAnonymousRoadmap: true)
        )
        let groups = try #require(result)
        #expect(groups.count == 1)
        let paths = counter.recorded
        #expect(paths.contains { $0.contains("/columns/") })
        #expect(paths.contains { $0.contains("/feature-requests") })
    }

    @Test func disallowedChangelogMakesNoRequests() async throws {
        let counter = RequestCounter()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            counter.record(request.url?.path ?? "")
            return (makeHTTPResponse(), Data("{}".utf8))
        }
        let result = try await loadChangelogEntries(
            client: Self.makeAPIClient(),
            config: makePermissionConfig(allowAnonymousChangelog: false)
        )
        #expect(result == nil)
        #expect(counter.recorded.isEmpty)
    }

    @Test func allowedChangelogFetchesEntries() async throws {
        let counter = RequestCounter()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            let path = request.url?.path ?? ""
            counter.record(path)
            let entry: [String: Any] = [
                "id": "e-perm-1",
                "title": "Version 1.0",
                "body": "First release",
                "versionLabel": "1.0.0",
                "publishedAt": "2026-01-01T00:00:00.000Z",
                "linkedRequests": []
            ]
            return (makeHTTPResponse(), try encodeJSON(["entries": [entry]]))
        }
        let result = try await loadChangelogEntries(
            client: Self.makeAPIClient(),
            config: makePermissionConfig(allowAnonymousChangelog: true)
        )
        let entries = try #require(result)
        #expect(entries.count == 1)
        #expect(entries.first?.id == "e-perm-1")
        #expect(counter.recorded.contains { $0.contains("/changelog") })
    }

    @Test func typedAuthenticationRequiredStillWinsOverBare401Mapping() async throws {
        // Changelog-style envelope with a machine-readable code must keep
        // mapping through typedError even on a permission-gated endpoint.
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (
                makeHTTPResponse(status: 401),
                try encodeJSON(["error": "Sign in", "code": "authentication_required"])
            )
        }
        do {
            _ = try await Self.makeAPIClient().toggleVote(featureRequestId: "fr-1", userToken: "tok")
            Issue.record("Expected authenticationRequired")
        } catch let error as FeedbackClientError {
            #expect(error == .authenticationRequired)
        }
    }
}
