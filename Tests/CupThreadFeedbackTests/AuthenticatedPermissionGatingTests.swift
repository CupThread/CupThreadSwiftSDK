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

// MARK: - Resolved access vs. provider presence (issue #297)

/// `supportsAuthentication` reports provider presence only; the permission
/// preflights must resolve whether a bearer token can actually be produced
/// right now. A host that installs its provider unconditionally (the norm)
/// and a signed-out user therefore resolve to *no* access.
@Suite("Resolved authenticated access")
struct ResolvedAuthenticatedAccessTests {
    @Test func providerReturningTokenResolvesToAccess() async {
        let client = makeClient(authenticationProvider: { "signed-in-jwt" })
        #expect(await client.resolveAuthenticatedAccess())
    }

    @Test func providerReturningNilOrBlankResolvesToNoAccess() async {
        #expect(await makeClient(authenticationProvider: { nil }).resolveAuthenticatedAccess() == false)
        #expect(await makeClient(authenticationProvider: { "" }).resolveAuthenticatedAccess() == false)
        #expect(await makeClient(authenticationProvider: { "   " }).resolveAuthenticatedAccess() == false)
    }

    @Test func clientWithoutProviderResolvesToNoAccess() async {
        #expect(await makeClient().resolveAuthenticatedAccess() == false)
        // Provider presence alone — the legacy flag — is not access.
        #expect(makeClient(authenticationProvider: { nil }).supportsAuthentication)
        #expect(await makeClient(authenticationProvider: { nil }).resolveAuthenticatedAccess() == false)
    }

    /// Truth table for the roadmap/changelog placeholder decision: an
    /// unsettled verdict never blocks (no placeholder flash while the
    /// provider has not answered), a settled denial does, and a server 401
    /// overrides a permitted preflight.
    @Test func surfacePermissionBlockingTruthTable() {
        // Undecided: the surface keeps its loading state.
        #expect(!isSurfacePermissionBlocked(verdictResolved: false, permitted: false, rejectedByServer: false))
        #expect(!isSurfacePermissionBlocked(verdictResolved: false, permitted: false, rejectedByServer: true))
        // Settled: preflight denial blocks, permission does not.
        #expect(isSurfacePermissionBlocked(verdictResolved: true, permitted: false, rejectedByServer: false))
        #expect(!isSurfacePermissionBlocked(verdictResolved: true, permitted: true, rejectedByServer: false))
        // Server 401 after a permitted preflight blocks too.
        #expect(isSurfacePermissionBlocked(verdictResolved: true, permitted: true, rejectedByServer: true))
    }
}

// MARK: - Network-level preflight bypass (issue #233)

@Suite("Authenticated client permission fetching", .serialized)
struct AuthenticatedPermissionFetchingTests {
    static let apiHost = "permission-gate-auth.example.com"

    /// Console config with every anonymous-access switch off, as JSON for the
    /// `/config/:appKey` endpoint (decoding defaults omitted flags to `true`).
    static var lockedDownConfigJSON: [String: Any] {
        [
            "appId": "app-1",
            "appKey": "app_testkey123456",
            "slug": "demo",
            "name": "Demo",
            "allowPublic": true,
            "allowedPlatforms": ["ios", "macos"],
            "allowAnonymousRoadmap": false,
            "allowAnonymousVote": false,
            "allowAnonymousFeedback": false,
            "allowAnonymousChangelog": false
        ]
    }

    static var columnJSON: [String: Any] {
        [
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
    }

    /// Thread-safe sign-in state so a test can flip the provider's answer
    /// between two loads (issue #297: every load must re-resolve).
    private final class AuthSessionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var signedIn = false
        var isSignedIn: Bool {
            get { lock.lock(); defer { lock.unlock() }; return signedIn }
            set { lock.lock(); defer { lock.unlock() }; signedIn = newValue }
        }
    }

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

    /// A client whose config store is fully isolated (unique in-memory
    /// last-good cache), for tests that go through `cachedAppConfig`.
    static func makeIsolatedClient(
        appKey: String,
        authenticationProvider: (@Sendable () async -> String?)?
    ) -> FeedbackClient {
        makeClient(
            baseURL: URL(string: "https://\(apiHost)")!,
            appKey: appKey,
            configStore: AppConfigStore(lastGood: SdkConfigCache(
                appKey: appKey,
                storage: InMemoryAuthConfigStorage()
            )),
            authenticationProvider: authenticationProvider
        )
    }

    @Test func disallowedRoadmapStillFetchesForAuthenticatedClient() async throws {
        let counter = RequestCounter()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            counter.record(request)
            if request.url?.path.contains("/columns/") == true {
                return (makeHTTPResponse(), try encodeJSON(["columns": [Self.columnJSON]]))
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

    // MARK: Signed-out user of an unconditionally-installed provider (#297)

    @Test func signedOutProviderIssuesNoRoadmapOrChangelogRequests() async throws {
        let counter = RequestCounter()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            counter.record(request)
            return (makeHTTPResponse(status: 500), try encodeJSON(["error": "must not be reached"]))
        }
        let client = makeClient(
            baseURL: URL(string: "https://\(Self.apiHost)")!,
            authenticationProvider: { nil }
        )
        let roadmap = try await loadRoadmapGroups(
            client: client,
            userToken: "tok",
            query: nil,
            config: makeLockedDownConfig()
        )
        #expect(roadmap == nil)
        let changelog = try await loadChangelogEntries(
            client: client,
            config: makeLockedDownConfig()
        )
        #expect(changelog == nil)
        #expect(counter.recorded.isEmpty)
    }

    @Test func prepareChangelogOverlayReturnsNilWithoutChangelogRequestForSignedOutUser() async throws {
        let counter = RequestCounter()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            counter.record(request)
            if request.url?.path.contains("/config/") == true {
                return (makeHTTPResponse(), try encodeJSON(Self.lockedDownConfigJSON))
            }
            return (makeHTTPResponse(status: 500), try encodeJSON(["error": "must not be reached"]))
        }
        let client = Self.makeIsolatedClient(appKey: "app_perm_auth_signedout", authenticationProvider: { nil })

        let prepared = try await client.prepareChangelogOverlay(onlyIfUnseen: false)

        #expect(prepared == nil)
        #expect(counter.recorded.contains { $0.contains("/config/") })
        #expect(!counter.recorded.contains { $0.contains("/changelog") })
    }

    @Test func providerFlippingFromSignedOutToTokenFetchesOnNextLoad() async throws {
        let session = AuthSessionBox()
        let counter = RequestCounter()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            counter.record(request)
            if request.url?.path.contains("/columns/") == true {
                return (makeHTTPResponse(), try encodeJSON(["columns": [Self.columnJSON]]))
            }
            return (makeHTTPResponse(), try encodeJSON(["requests": [], "total": 0]))
        }
        let client = makeClient(
            baseURL: URL(string: "https://\(Self.apiHost)")!,
            authenticationProvider: { session.isSignedIn ? "signed-in-jwt" : nil }
        )
        let locked = makeLockedDownConfig()

        let first = try await loadRoadmapGroups(client: client, userToken: "tok", query: nil, config: locked)
        #expect(first == nil)
        #expect(counter.recorded.isEmpty)

        session.isSignedIn = true
        let second = try await loadRoadmapGroups(client: client, userToken: "tok", query: nil, config: locked)
        let groups = try #require(second)
        #expect(!groups.isEmpty)
        #expect(counter.authorizations.allSatisfy { $0 == "Bearer signed-in-jwt" })
    }

    // MARK: Server 401 after a permitted preflight (#297)

    @Test func roadmapServer401SurfacesAsPermissionRejection() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 401), try encodeJSON(["error": "authentication_required"]))
        }
        let client = makeClient(
            baseURL: URL(string: "https://\(Self.apiHost)")!,
            authenticationProvider: { "expired-jwt" }
        )
        do {
            _ = try await loadRoadmapGroups(
                client: client,
                userToken: "tok",
                query: nil,
                config: makeLockedDownConfig()
            )
            Issue.record("Expected the roadmap load to throw authenticationRequired")
        } catch {
            #expect(isSdkPermissionRejection(error))
            if case FeedbackClientError.authenticationRequired = error {} else {
                Issue.record("Expected .authenticationRequired, got \(error)")
            }
        }
    }

    @Test func changelogServer401SurfacesAsPermissionRejection() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 401), try encodeJSON(["error": "authentication_required"]))
        }
        let client = makeClient(
            baseURL: URL(string: "https://\(Self.apiHost)")!,
            authenticationProvider: { "expired-jwt" }
        )
        do {
            _ = try await loadChangelogEntries(client: client, config: makeLockedDownConfig())
            Issue.record("Expected the changelog load to throw authenticationRequired")
        } catch {
            #expect(isSdkPermissionRejection(error))
        }
    }

    @Test func overlaySelfLoadMapsServer401ToPermissionDenied() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            if request.url?.path.contains("/changelog") == true {
                return (makeHTTPResponse(status: 401), try encodeJSON(["error": "authentication_required"]))
            }
            return (makeHTTPResponse(), try encodeJSON(Self.lockedDownConfigJSON))
        }
        let client = Self.makeIsolatedClient(appKey: "app_perm_auth_overlay401", authenticationProvider: { "expired-jwt" })

        let content = await ChangelogOverlayView.fetchSelfLoadedContent(in: client)

        guard case .permissionDenied = content else {
            Issue.record("Expected .permissionDenied, got \(String(describing: content))")
            return
        }
    }

    @Test func prepareChangelogOverlayStaysHiddenWhenServerRejectsToken() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            if request.url?.path.contains("/changelog") == true {
                return (makeHTTPResponse(status: 401), try encodeJSON(["error": "authentication_required"]))
            }
            return (makeHTTPResponse(), try encodeJSON(Self.lockedDownConfigJSON))
        }
        let client = Self.makeIsolatedClient(appKey: "app_perm_auth_prepare401", authenticationProvider: { "expired-jwt" })

        let prepared = try await client.prepareChangelogOverlay(onlyIfUnseen: false)

        #expect(prepared == nil)
    }
}

/// In-memory ``SdkConfigCacheStorage`` so `cachedAppConfig`-based tests are
/// independent of the process-wide `UserDefaults`.
private final class InMemoryAuthConfigStorage: SdkConfigCacheStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ data: Data, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = data
    }
}
