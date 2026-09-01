import SwiftUI

/// User profile view showing public details, apps, and recent comments.
public struct UserProfileView: View {
    public let client: FeedbackClient
    public let userId: String

    @Environment(\.dismiss) private var dismiss
    @State private var profile: PublicUserProfileResponse?
    @State private var isLoading = true
    @State private var loadError: String?

    public init(client: FeedbackClient, userId: String) {
        self.client = client
        self.userId = userId
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if isLoading {
                    ProgressView()
                        .padding(.top, 32)
                } else if let loadError {
                    LoadErrorView(message: loadError) {
                        await loadProfile()
                    }
                    .padding(.top, 32)
                } else if let response = profile {
                    profileHeader(response.profile)

                    if !response.apps.isEmpty {
                        appsSection(response.apps)
                    }

                    if !response.hideComments {
                        commentsSection(response.recentComments)
                    }
                }
            }
            .padding(16)
        }
        .refreshable { await loadProfile() }
        .navigationTitle(profile?.profile.displayName ?? CupThreadStrings.tr("cupthread.profile.title"))
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(CupThreadStrings.tr("cupthread.whatsnew.close_button")) {
                    dismiss()
                }
            }
        }
        .task { await loadProfile() }
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

                if let websiteUrl = profile.websiteUrl, let url = URL(string: websiteUrl) {
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

    @MainActor
    private func loadProfile() async {
        isLoading = true
        loadError = nil
        do {
            profile = try await client.fetchUserProfile(userId: userId)
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}
