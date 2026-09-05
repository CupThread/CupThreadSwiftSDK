import SwiftUI

/// Comment thread for a feature request.
///
/// Displays comments in a flat list with @reply indicators and
/// author avatars. Users can post new comments and reply to existing ones.
public struct CommentsView: View {
    public let client: FeedbackClient
    public let userToken: String
    public let featureRequestId: String
    public let featureRequestTitle: String

    @Environment(\.dismiss) private var dismiss
    @State private var comments: [FeatureRequestComment] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var draft = CommentDraft()
    @State private var isSubmitting = false
    @State private var submitError: String?
    @State private var selectedProfileUserId: String?

    public init(
        client: FeedbackClient,
        userToken: String,
        featureRequestId: String,
        featureRequestTitle: String
    ) {
        self.client = client
        self.userToken = userToken
        self.featureRequestId = featureRequestId
        self.featureRequestTitle = featureRequestTitle
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if isLoading {
                        ProgressView()
                            .padding(.top, 32)
                    } else if let loadError {
                        LoadErrorView(message: loadError) {
                            await loadComments()
                        }
                        .padding(.top, 32)
                    } else if comments.isEmpty {
                        ContentUnavailableView {
                            Label(CupThreadStrings.tr("cupthread.comments.empty_title"), systemImage: "bubble.left.and.bubble.right")
                        } description: {
                            Text(CupThreadStrings.tr("cupthread.comments.empty_description"))
                        }
                        .padding(.top, 48)
                    } else {
                        ForEach(comments) { comment in
                            commentRow(comment)
                        }
                    }
                }
                .padding(16)
            }
            .refreshable { await loadComments() }

            Divider()

            composeArea
        }
        .navigationTitle(featureRequestTitle)
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
        .sheet(isPresented: Binding(
            get: { selectedProfileUserId != nil },
            set: { if !$0 { selectedProfileUserId = nil } }
        )) {
            if let userId = selectedProfileUserId {
                NavigationStack {
                    UserProfileView(client: client, userId: userId)
                }
            }
        }
        .task { await loadComments() }
        .safeWebOpenURL()
    }

    private func commentRow(_ comment: FeatureRequestComment) -> some View {
        HStack(alignment: .top, spacing: 12) {
            commentAvatar(for: comment)

            VStack(alignment: .leading, spacing: 4) {
                authorHeader(for: comment)
                replyTag(for: comment)

                Text(comment.body)
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                replyButton(for: comment)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func commentAvatar(for comment: FeatureRequestComment) -> some View {
        if let clerkId = comment.authorClerkId {
            Button {
                selectedProfileUserId = clerkId
            } label: {
                AvatarView(url: comment.authorAvatarUrl, size: 32)
            }
            .buttonStyle(.plain)
        } else {
            AvatarView(url: comment.authorAvatarUrl, size: 32)
        }
    }

    @ViewBuilder
    private func authorHeader(for comment: FeatureRequestComment) -> some View {
        HStack {
            if let clerkId = comment.authorClerkId {
                Button {
                    selectedProfileUserId = clerkId
                } label: {
                    Text(comment.authorName ?? CupThreadStrings.tr("cupthread.features.anonymous"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            } else {
                Text(comment.authorName ?? CupThreadStrings.tr("cupthread.features.anonymous"))
                    .font(.subheadline.weight(.semibold))
            }
            Spacer()
            if let date = comment.createdAtDate {
                Text(date, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func replyTag(for comment: FeatureRequestComment) -> some View {
        if let replyTo = comment.replyToAuthorName {
            if let clerkId = comment.replyToClerkId {
                Button {
                    selectedProfileUserId = clerkId
                } label: {
                    Text("@\(replyTo)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            } else {
                Text("@\(replyTo)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    @ViewBuilder
    private func replyButton(for comment: FeatureRequestComment) -> some View {
        Button {
            draft.parentId = comment.id
            draft.replyToAuthorName = comment.authorName ?? CupThreadStrings.tr("cupthread.features.anonymous")
            draft.replyToClerkId = comment.authorClerkId
        } label: {
            Text(CupThreadStrings.tr("cupthread.comments.reply"))
                .font(.caption.weight(.medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    private var composeArea: some View {
        VStack(spacing: 8) {
            if let submitError {
                ErrorBanner(message: submitError)
            }

            if let replyTo = draft.replyToAuthorName {
                HStack {
                    Text(CupThreadStrings.tr("cupthread.comments.replying_to", replyTo))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        draft.parentId = nil
                        draft.replyToAuthorName = nil
                        draft.replyToClerkId = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(alignment: .bottom, spacing: 12) {
                TextField(CupThreadStrings.tr("cupthread.comments.compose_prompt"), text: $draft.body, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)

                Button {
                    Task { await submitComment() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSubmit ? Color.accentColor : Color.secondary.opacity(0.3))
                .disabled(!canSubmit || isSubmitting)
            }
        }
        .padding(16)
        .background(.background)
    }

    private var canSubmit: Bool {
        !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    private func loadComments() async {
        isLoading = true
        loadError = nil
        do {
            comments = try await client.fetchComments(featureRequestId: featureRequestId)
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func submitComment() async {
        isSubmitting = true
        submitError = nil
        do {
            let newComment = try await client.postComment(
                featureRequestId: featureRequestId,
                draft: draft,
                userToken: userToken
            )
            comments.append(newComment)
            draft.body = ""
            draft.parentId = nil
            draft.replyToAuthorName = nil
            draft.replyToClerkId = nil
        } catch {
            submitError = error.localizedDescription
        }
        isSubmitting = false
    }
}
