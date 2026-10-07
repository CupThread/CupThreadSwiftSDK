import SwiftUI

// MARK: - Vote gating

/// Extracted vote-pill enablement (#34). Own requests stay disabled, and a
/// resolved config with `allowAnonymousVote == false` disables every pill —
/// except when the client can attach a bearer token right now (the resolved
/// ``FeedbackClient/resolveAuthenticatedAccess()`` value): a signed-in user is
/// not bound by the *anonymous*-access switches, and the server stays
/// authoritative for actual 401/403 rejections.
enum FeatureVoteGate {
    /// Whether the vote action should be disabled for this request.
    /// `supportsAuthentication` defaults to `false` so a call site that forgets
    /// to thread it fails closed (the pre-#233 anonymous behavior). Call sites
    /// pass the *resolved* access value (`resolveAuthenticatedAccess()`), not the
    /// mere presence of a provider (issue #297).
    static func isActionDisabled(
        isOwnRequest: Bool,
        config: PublicAppConfig?,
        supportsAuthentication: Bool = false
    ) -> Bool {
        isOwnRequest || (!supportsAuthentication && !(config?.allowsAnonymousVote ?? true))
    }

    /// Accessibility hint key for the vote pill. Own-request copy wins when
    /// both reasons apply; the permission hint is used only for anonymous
    /// voting being switched off.
    static func hintKey(
        isOwnRequest: Bool,
        config: PublicAppConfig?,
        supportsAuthentication: Bool = false
    ) -> String {
        if isOwnRequest {
            return "cupthread.features.vote_own_hint"
        }
        if !supportsAuthentication && config?.allowsAnonymousVote == false {
            return "cupthread.permission.vote_hint"
        }
        return "cupthread.features.vote_toggle_hint"
    }
}

// MARK: - Submission / surface denials

/// Why a compose/submit surface should not be interactive.
enum SdkSubmissionDenial: Equatable, Sendable {
    /// The console allows the submission.
    case none
    /// `allowAnonymousFeedback` is off.
    case anonymousFeedbackDisabled
    /// The draft's platform is outside a non-empty `allowedPlatforms` list.
    case platformNotAllowed

    /// Preflight for the feedback composer. `nil` config fails open. A client
    /// that can produce a bearer token for the current user (resolved access,
    /// not mere provider presence) is not bound by the anonymous-feedback
    /// switch; platform allow-lists still apply.
    static func forFeedback(
        config: PublicAppConfig?,
        platform: FeedbackPlatform,
        supportsAuthentication: Bool = false
    ) -> SdkSubmissionDenial {
        guard let config else { return .none }
        guard config.allowsAnonymousFeedback || supportsAuthentication else {
            return .anonymousFeedbackDisabled
        }
        guard config.allows(platform: platform) else { return .platformNotAllowed }
        return .none
    }

    /// Preflight for the feature-request composer. Platform allow-lists
    /// apply to feedback submissions, not feature requests. A client that can
    /// produce a bearer token for the current user is not bound by the
    /// anonymous switch.
    static func forFeatureRequest(
        config: PublicAppConfig?,
        supportsAuthentication: Bool = false
    ) -> SdkSubmissionDenial {
        guard let config else { return .none }
        return (config.allowsAnonymousFeedback || supportsAuthentication) ? .none : .anonymousFeedbackDisabled
    }

    @ViewBuilder
    var placeholder: some View {
        switch self {
        case .none:
            EmptyView()
        case .platformNotAllowed:
            SdkPermissionDeniedView(
                titleKey: "cupthread.permission.platform_title",
                descriptionKey: "cupthread.permission.platform_description"
            )
        case .anonymousFeedbackDisabled:
            SdkPermissionDeniedView(
                titleKey: "cupthread.permission.feedback_title",
                descriptionKey: "cupthread.permission.feedback_description"
            )
        }
    }

    var featureRequestPlaceholder: some View {
        SdkPermissionDeniedView(
            titleKey: "cupthread.permission.requests_title",
            descriptionKey: "cupthread.permission.requests_description"
        )
    }
}

// MARK: - Roadmap load plan

/// Whether the roadmap board should issue its columns/requests fetches.
enum RoadmapLoadPlan: Equatable, Sendable {
    /// Fetch columns and feature requests.
    case load
    /// Anonymous roadmap access is off — skip the network and show a
    /// permission placeholder instead.
    case skip
}

/// Decides whether ``RoadmapBoardView`` should hit the network.
///
/// A `nil` config fails open (the server stays authoritative). A resolved
/// config with ``PublicAppConfig/allowsAnonymousRoadmap`` `false` skips —
/// unless `supportsAuthentication` (the resolved access value) is set, in
/// which case the client's bearer token satisfies the *anonymous*-access
/// preflight and the fetch proceeds.
func roadmapLoadPlan(config: PublicAppConfig?, supportsAuthentication: Bool = false) -> RoadmapLoadPlan {
    (supportsAuthentication || (config?.allowsAnonymousRoadmap ?? true)) ? .load : .skip
}

/// Loads the board's groups, or returns `nil` without issuing requests when
/// the console disallows anonymous roadmap access and the client cannot
/// produce a bearer token for the current user.
func loadRoadmapGroups(
    client: FeedbackClient,
    userToken: String,
    query: String?,
    config: PublicAppConfig?,
    skipInitialAdmissionRecord: Bool = false
) async throws -> [RoadmapGroup]? {
    let supportsAuthentication = await client.resolveAuthenticatedAccess()
    guard roadmapLoadPlan(config: config, supportsAuthentication: supportsAuthentication) == .load else {
        return nil
    }
    let isQueryActive = query.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
    async let columns = client.fetchColumns()
    let requests = try await collectAllRequests { cursor in
        if isQueryActive {
            if cursor == nil && skipInitialAdmissionRecord {
                // The caller already committed an admission slot for the initial page via `waitForAdmission`.
            } else {
                await client.searchThrottle.recordQueryFetch()
            }
        }
        return try await client.fetchFeatureRequests(
            userToken: userToken,
            limit: 200,
            query: query,
            cursor: cursor
        )
    }
    return makeGroups(columns: try await columns, requests: requests)
}

// MARK: - Changelog load plan

/// Whether changelog surfaces should issue their entries fetch.
enum ChangelogLoadPlan: Equatable, Sendable {
    /// Fetch changelog entries.
    case load
    /// Anonymous changelog access is off — skip the network and show a
    /// permission placeholder instead.
    case skip
}

/// Decides whether ``WhatsNewView`` and ``ChangelogOverlayView`` should hit the network.
///
/// A `nil` config fails open (the server stays authoritative). A resolved
/// config with ``PublicAppConfig/allowsAnonymousChangelog`` `false` skips —
/// unless `supportsAuthentication` (the resolved access value) is set, in
/// which case the client's bearer token satisfies the *anonymous*-access
/// preflight and the fetch proceeds.
func changelogLoadPlan(config: PublicAppConfig?, supportsAuthentication: Bool = false) -> ChangelogLoadPlan {
    (supportsAuthentication || (config?.allowsAnonymousChangelog ?? true)) ? .load : .skip
}

/// Fetches changelog entries, or returns `nil` without issuing requests when
/// the console disallows anonymous changelog access and the client cannot
/// produce a bearer token for the current user.
func loadChangelogEntries(
    client: FeedbackClient,
    config: PublicAppConfig?
) async throws -> [ChangelogEntry]? {
    let supportsAuthentication = await client.resolveAuthenticatedAccess()
    guard changelogLoadPlan(config: config, supportsAuthentication: supportsAuthentication) == .load else {
        return nil
    }
    return try await client.fetchChangelog()
}

// MARK: - Server permission rejection

/// Whether a thrown error is the server rejecting a load the client believed
/// it could make — the `401 authentication_required` mapping. Roadmap,
/// changelog, and overlay load paths render the permission placeholder (or
/// keep the overlay hidden) for it instead of the generic error state: the
/// preflight resolved a token but the server disagreed, e.g. because the
/// token expired between the check and the send (issue #297).
func isSdkPermissionRejection(_ error: Error) -> Bool {
    guard let clientError = error as? FeedbackClientError else { return false }
    if case .authenticationRequired = clientError { return true }
    return false
}

/// Whether a surface must render its permission placeholder (issue #297).
///
/// An *unsettled* verdict — a locked-down console whose resolved-access state
/// has not arrived yet — blocks nothing: the surface keeps its loading state
/// instead of flashing the placeholder for a signed-in user whose provider
/// has not answered. Settled verdicts block when the preflight denied, or
/// when the server's 401 overrode a permitted one.
func isSurfacePermissionBlocked(
    verdictResolved: Bool,
    permitted: Bool,
    rejectedByServer: Bool
) -> Bool {
    guard verdictResolved else { return false }
    return !permitted || rejectedByServer
}

// MARK: - Permission placeholder

/// Full-surface placeholder for the console's *permission* switches (issue
/// #34): the surface is on, but the current user may not use it — anonymous
/// users are bound by the `allowAnonymous*` switches, while clients that can
/// produce a bearer token pass this preflight (the server stays
/// authoritative) — or the reporting platform is outside the allow-list.
/// Distinct from ``FeatureDisabledView``, which covers the visibility switches.
struct SdkPermissionDeniedView: View {
    let titleKey: String
    let descriptionKey: String
    var systemImage: String = "lock.circle"

    var body: some View {
        ContentUnavailableView {
            Label(CupThreadStrings.tr(titleKey), systemImage: systemImage)
        } description: {
            Text(CupThreadStrings.tr(descriptionKey))
        }
        .padding()
        .accessibilityIdentifier("cupthread.permission.denied")
    }
}
