import SwiftUI

/// User profile view showing public details, apps, and recent comments.
public struct UserProfileView: View {
    public let client: FeedbackClient
    public let userId: String

    @Environment(\.dismiss) private var dismiss
    @State private var profile: PublicUserProfileResponse?
    /// First-load lifecycle and stale-write generation tracking (CONC-4).
    @State private var loadState = SurfaceLoadState()

    public init(client: FeedbackClient, userId: String) {
        self.client = client
        self.userId = userId
    }

    /// Internal initializer for tests: `initialProfile` and
    /// `initialLoadState` seed the load lifecycle so tests can pin the
    /// reload-preservation rendering without driving a fetch (issue #545).
    init(
        client: FeedbackClient,
        userId: String,
        initialProfile: PublicUserProfileResponse?,
        initialLoadState: SurfaceLoadState = SurfaceLoadState()
    ) {
        self.client = client
        self.userId = userId
        _profile = State(initialValue: initialProfile)
        _loadState = State(initialValue: initialLoadState)
    }

    // MARK: View-level test accessors (reads reflect the seeded @State)

    var isLoading: Bool { loadState.isLoading }
    var hasLoadedOnce: Bool { loadState.hasLoadedOnce }
    var loadError: String? { loadState.loadError }
    /// Transient notice for a failed refresh whose profile stays on screen
    /// (issue #545). `nil` while the full-screen error owns the surface.
    var reloadNotice: String? { loadState.reloadNotice }

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // A reload never collapses the rendered profile to a bare
                // spinner (#545): the loading branch owns the surface only
                // before the first successful load, matching the #59/#534
                // preserve-content contract shared by the other surfaces.
                if loadState.isLoading && !loadState.hasLoadedOnce {
                    ProgressView()
                        .padding(.top, 32)
                } else if let loadError = loadState.loadError, profile == nil {
                    // Full-screen error only when there is nothing to show;
                    // a failure with a rendered profile becomes the inline
                    // notice overlay below instead.
                    LoadErrorView(message: loadError) {
                        await loadProfile()
                    }
                    .padding(.top, 32)
                } else if let response = profile {
                    profileHeader(response.profile)

                    if !response.publicApps.isEmpty {
                        appsSection(response.publicApps)
                    }

                    // Comment visibility is applied server-side: a user who
                    // hides comments receives an empty `recentComments`
                    // array, so the section's empty state is the correct
                    // presentation (issue #505).
                    commentsSection(response.recentComments)
                }
            }
            .padding(16)
        }
        .refreshable { await loadProfile() }
        .navigationTitle(profile?.profile.displayName ?? CupThreadStrings.tr("cupthread.profile.title"))
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // A failed refresh keeps the rendered profile in place; the failure
        // surfaces as this transient top banner (issue #534/#545). A
        // first-load failure has no content to preserve and uses the
        // full-screen `LoadErrorView` instead.
        .overlay(alignment: .top) {
            if let reloadNotice = loadState.reloadNotice {
                InlineNoticeBanner(message: reloadNotice)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .autoClearNotice($loadState.reloadNotice)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(CupThreadStrings.tr("cupthread.whatsnew.close_button")) {
                    dismiss()
                }
            }
        }
        .task { await loadProfile() }
        .safeWebOpenURL()
    }

    private func profileHeader(_ profile: UserProfile) -> some View {
        VStack(spacing: 16) {
            AvatarView(url: profile.avatarUrl, size: 80)

            VStack(spacing: 4) {
                Text(profile.displayName ?? CupThreadStrings.tr("cupthread.features.anonymous"))
                    .font(.title2.weight(.bold))

                if let bio = profile.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let websiteUrl = profile.websiteUrl, let url = normalizeWebsiteURL(websiteUrl) {
                    Link(destination: url) {
                        Label(websiteUrl, systemImage: "link")
                            .font(.footnote)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func appsSection(_ apps: [PublicAppSummary]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(CupThreadStrings.tr("cupthread.profile.apps"))
                .font(.headline)

            ForEach(apps) { app in
                HStack(spacing: 12) {
                    AvatarView(url: app.iconUrl, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(.subheadline.weight(.semibold))
                        if let desc = app.description {
                            Text(desc)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                }
                .padding(12)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func commentsSection(_ comments: [UserProfileComment]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(CupThreadStrings.tr("cupthread.profile.recent_comments"))
                .font(.headline)

            if comments.isEmpty {
                Text(CupThreadStrings.tr("cupthread.profile.no_comments"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(comments) { comment in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(comment.featureRequestTitle)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if let date = try? Date(comment.createdAt, strategy: .iso8601) {
                                Text(date, format: .relative(presentation: .named))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        Text(comment.body)
                            .font(.subheadline)
                    }
                    .padding(12)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    /// Internal for view-level tests (`@testable`), mirroring
    /// `CommentsView.loadComments()`: `@State` writes are not observable on
    /// a unit-constructed view, so the tests drive the real method against
    /// a mocked client and pin the `@State` mutations with the source-scan
    /// pattern.
    @MainActor
    func loadProfile() async {
        let generation = loadState.startLoading()
        var wasCancelled = false
        // Cancellation has no empty/error verdict to render (#442).
        defer {
            loadState.finishLoading(generation: generation, wasCancelled: wasCancelled || Task.isCancelled)
        }
        do {
            let fetched = try await client.fetchUserProfile(userId: userId)
            // A superseded load (pull-to-refresh racing the initial task,
            // retry taps stacking up) must not clobber the newer run's
            // profile.
            guard !Task.isCancelled, loadState.isCurrent(generation: generation) else { return }
            profile = fetched
            loadState.recordSuccess(generation: generation)
        } catch {
            // A cancelled load never reached a verdict — keep whatever
            // profile state was rendered before. A superseded run must not
            // write either; both leave the surface to the surviving load.
            wasCancelled = error.isSdkCancellation || Task.isCancelled
            guard loadState.isCurrent(generation: generation), !wasCancelled else { return }
            // Issue #545: a failed reload keeps the rendered profile and
            // degrades to the inline notice; only a failure with nothing to
            // show fills the surface with the full-screen error (#59/#534).
            loadState.handleFailure(
                error: error,
                generation: generation,
                hasExistingContent: profile != nil
            )
        }
    }
}
