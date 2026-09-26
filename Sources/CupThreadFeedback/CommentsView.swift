import SwiftUI

/// Comment thread for a feature request.
///
/// Displays comments in a flat list with @reply indicators and
/// author avatars. Users can post new comments and reply to existing ones.
///
/// Posting is signed-in-only on the server: create the client with an
/// authentication provider (``FeedbackClient/init(configuration:session:authenticationProvider:)``)
/// so signed-in users can contribute. When the client cannot present a
/// signed-in identity, the composer is replaced by a deliberate
/// signed-out notice and the reply actions are hidden.
public struct CommentsView: View {
    public let client: FeedbackClient
    public let userToken: String
    public let featureRequestId: String
    public let featureRequestTitle: String

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
        .composerDismissGuard(
            hasContent: draft.hasContent,
            isSubmitting: isSubmitting,
            discardTitleKey: "cupthread.comments.discard_title"
        )
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
        let display = comment.displayModel
        let row = HStack(alignment: .top, spacing: 12) {
            if display.isModerated {
                moderatedAvatar
            } else {
                commentAvatar(for: comment)
            }

            VStack(alignment: .leading, spacing: 4) {
                if display.isModerated {
                    moderatedHeader(for: comment)
                } else {
                    authorHeader(for: comment)
                }

                replyTag(for: comment)

                Text(display.displayBody)
                    .font(.subheadline)
                    .foregroundStyle(display.isModerated ? .secondary : .primary)
                    .italic(display.isModerated)

                if display.canReply, client.supportsAuthentication {
                    replyButton(for: comment)
                }
            }
        }
        .padding(.vertical, 8)

        return Group {
            if display.isModerated {
                row
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(display.displayBody)
            } else {
                row
            }
        }
    }

    private var moderatedAvatar: some View {
        Image(systemName: "slash.circle")
            .resizable()
            .scaledToFit()
            .frame(width: 18, height: 18)
            .foregroundStyle(.tertiary)
            .frame(width: 32, height: 32)
            .background(Color.secondary.opacity(0.12))
            .clipShape(Circle())
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func moderatedHeader(for comment: FeatureRequestComment) -> some View {
        HStack {
            Spacer()
            if let date = comment.createdAtDate {
                Text(date, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
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
            guard !comment.isModerated else { return }
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

    @ViewBuilder
    private var composeArea: some View {
        // Comment creation is signed-in-only on the server. When this client
        // has no way to present a signed-in identity, show a deliberate
        // signed-out notice instead of a composer that can never succeed.
        if client.supportsAuthentication {
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
                    #if os(tvOS)
                    TextField(CupThreadStrings.tr("cupthread.comments.compose_prompt"), text: $draft.body, axis: .vertical)
                        .lineLimit(1...5)
                    #else
                    TextField(CupThreadStrings.tr("cupthread.comments.compose_prompt"), text: $draft.body, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.roundedBorder)
                    #endif

                    Button {
                        Task { await submitComment() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                    }
                    #if os(tvOS)
                    .buttonStyle(.borderedProminent)
                    #else
                    .buttonStyle(.plain)
                    .foregroundStyle(canSubmit ? Color.accentColor : Color.secondary.opacity(0.3))
                    #endif
                    .disabled(!canSubmit || isSubmitting)
                }
            }
            .padding(16)
            .background(.background)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(CupThreadStrings.tr("cupthread.comments.sign_in_required"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(16)
            .background(.background)
            .accessibilityElement(children: .combine)
        }
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
            // A cancelled load (dismissal, restart for another request) never
            // reached a verdict — keep the currently rendered comments.
            guard !error.isSdkCancellation else { return }
            loadError = FriendlyError.message(for: error)
        }
        isLoading = false
    }

    @MainActor
    private func submitComment() async {
        isSubmitting = true
        defer { isSubmitting = false }
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
            guard !error.isSdkCancellation else { return }
            submitError = FriendlyError.message(for: error)
        }
    }
}
