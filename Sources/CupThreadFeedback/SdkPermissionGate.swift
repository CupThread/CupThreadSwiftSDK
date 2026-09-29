import SwiftUI

// MARK: - Vote gating

/// Extracted vote-pill enablement (#34). Own requests stay disabled, and a
/// resolved config with `allowAnonymousVote == false` disables every pill —
/// except when the client can attach a bearer token
/// (`FeedbackClient.supportsAuthentication`): a signed-in host is not bound by
/// the *anonymous*-access switches, and the server stays authoritative for
/// actual 401/403 rejections.
enum FeatureVoteGate {
    /// Whether the vote action should be disabled for this request.
    /// `supportsAuthentication` defaults to `false` so a call site that forgets
    /// to thread it fails closed (the pre-#233 anonymous behavior).
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
    /// with an authentication provider is not bound by the anonymous-feedback
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
    /// apply to feedback submissions, not feature requests. A client with an
    /// authentication provider is not bound by the anonymous switch.
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
/// unless `supportsAuthentication` is set, in which case the client's bearer
/// token satisfies the *anonymous*-access preflight and the fetch proceeds.
func roadmapLoadPlan(config: PublicAppConfig?, supportsAuthentication: Bool = false) -> RoadmapLoadPlan {
    (supportsAuthentication || (config?.allowsAnonymousRoadmap ?? true)) ? .load : .skip
}

/// Loads the board's groups, or returns `nil` without issuing requests when
/// the console disallows anonymous roadmap access and the client has no
/// authentication provider.
func loadRoadmapGroups(
    client: FeedbackClient,
    userToken: String,
    query: String?,
    config: PublicAppConfig?
) async throws -> [RoadmapGroup]? {
    guard roadmapLoadPlan(config: config, supportsAuthentication: client.supportsAuthentication) == .load else {
        return nil
    }
    async let columns = client.fetchColumns()
    let requests = try await collectAllRequests { cursor in
        try await client.fetchFeatureRequests(
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
/// unless `supportsAuthentication` is set, in which case the client's bearer
/// token satisfies the *anonymous*-access preflight and the fetch proceeds.
func changelogLoadPlan(config: PublicAppConfig?, supportsAuthentication: Bool = false) -> ChangelogLoadPlan {
    (supportsAuthentication || (config?.allowsAnonymousChangelog ?? true)) ? .load : .skip
}

/// Fetches changelog entries, or returns `nil` without issuing requests when
/// the console disallows anonymous changelog access and the client has no
/// authentication provider.
func loadChangelogEntries(
    client: FeedbackClient,
    config: PublicAppConfig?
) async throws -> [ChangelogEntry]? {
    guard changelogLoadPlan(config: config, supportsAuthentication: client.supportsAuthentication) == .load else {
        return nil
    }
    return try await client.fetchChangelog()
}

// MARK: - Permission placeholder

/// Full-surface placeholder for the console's *permission* switches (issue
/// #34): the surface is on, but the current user may not use it — anonymous
/// users are bound by the `allowAnonymous*` switches, while clients with an
/// authentication provider pass this preflight (the server stays
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
