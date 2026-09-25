import SwiftUI

// MARK: - Vote gating

/// Extracted vote-pill enablement (#34). Own requests stay disabled, and a
/// resolved config with `allowAnonymousVote == false` disables every pill.
enum FeatureVoteGate {
    /// Whether the vote action should be disabled for this request.
    static func isActionDisabled(isOwnRequest: Bool, config: PublicAppConfig?) -> Bool {
        isOwnRequest || !(config?.allowsAnonymousVote ?? true)
    }

    /// Accessibility hint key for the vote pill. Own-request copy wins when
    /// both reasons apply; the permission hint is used only for anonymous
    /// voting being switched off.
    static func hintKey(isOwnRequest: Bool, config: PublicAppConfig?) -> String {
        if isOwnRequest {
            return "cupthread.features.vote_own_hint"
        }
        if config?.allowsAnonymousVote == false {
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

    /// Preflight for the feedback composer. `nil` config fails open.
    static func forFeedback(config: PublicAppConfig?, platform: FeedbackPlatform) -> SdkSubmissionDenial {
        guard let config else { return .none }
        guard config.allowsAnonymousFeedback else { return .anonymousFeedbackDisabled }
        guard config.allows(platform: platform) else { return .platformNotAllowed }
        return .none
    }

    /// Preflight for the feature-request composer. Platform allow-lists
    /// apply to feedback submissions, not feature requests.
    static func forFeatureRequest(config: PublicAppConfig?) -> SdkSubmissionDenial {
        guard let config else { return .none }
        return config.allowsAnonymousFeedback ? .none : .anonymousFeedbackDisabled
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
/// config with ``PublicAppConfig/allowsAnonymousRoadmap`` `false` skips.
func roadmapLoadPlan(config: PublicAppConfig?) -> RoadmapLoadPlan {
    (config?.allowsAnonymousRoadmap ?? true) ? .load : .skip
}

/// Loads the board's groups, or returns `nil` without issuing requests when
/// the console disallows anonymous roadmap access.
func loadRoadmapGroups(
    client: FeedbackClient,
    userToken: String,
    query: String?,
    config: PublicAppConfig?
) async throws -> [RoadmapGroup]? {
    guard roadmapLoadPlan(config: config) == .load else { return nil }
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
/// config with ``PublicAppConfig/allowsAnonymousChangelog`` `false` skips.
func changelogLoadPlan(config: PublicAppConfig?) -> ChangelogLoadPlan {
    (config?.allowsAnonymousChangelog ?? true) ? .load : .skip
}

/// Fetches changelog entries, or returns `nil` without issuing requests when
/// the console disallows anonymous changelog access.
func loadChangelogEntries(
    client: FeedbackClient,
    config: PublicAppConfig?
) async throws -> [ChangelogEntry]? {
    guard changelogLoadPlan(config: config) == .load else { return nil }
    return try await client.fetchChangelog()
}

// MARK: - Permission placeholder

/// Full-surface placeholder for the console's *permission* switches (issue
/// #34): the surface is on, but the current user (always anonymous in the
/// SDK) may not use it, or the reporting platform is outside the allow-list.
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
