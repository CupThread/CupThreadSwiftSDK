import SwiftUI

/// Comment thread for a feature request.
///
/// Displays comments in a flat list with @reply indicators and
/// author avatars. Users can post new comments and reply to existing ones.
///
/// Posting is signed-in-only on the server: create the client with an
/// authentication provider (``FeedbackClient/init(configuration:session:authenticationProvider:)``)
/// so signed-in users can contribute. Whether the interactive affordances
/// render follows the *resolved* access verdict
/// (``FeedbackClient/resolveAuthenticatedAccess()``), re-read on every load —
/// provider presence alone cannot tell a signed-out user of an
/// unconditionally-installed provider apart (BUG-24). When no signed-in
/// access can be resolved, the composer is replaced by a deliberate
/// signed-out notice and the reply actions are hidden.
public struct CommentsView: View {
    public let client: FeedbackClient
    public let userToken: String
    public let featureRequestId: String
    public let featureRequestTitle: String

    @State private var comments: [FeatureRequestComment] = []
    /// First-load lifecycle and stale-write generation tracking (CONC-4).
    @State private var loadState = SurfaceLoadState()
    @State private var isCommentsUnavailable = false
    /// Whether a request sent right now could carry the signed-in identity's
    /// bearer token. Resolved at the start of every load (BUG-24) —
    /// `supportsAuthentication` reports provider presence only, and the user
    /// can sign in or out while the thread is presented. Fail-closed until
    /// then: the interactive affordances stay hidden for an undecided verdict.
    @State private var isAuthenticated = false
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

    /// Test seam mirroring `FeatureRequestComposeView`: `preResolvedAuthentication`
    /// injects the resolved access verdict for view-level tests; production
    /// presentations use the public initializer and the view resolves the
    /// verdict on every load.
    init(
        client: FeedbackClient,
        userToken: String,
        featureRequestId: String,
        featureRequestTitle: String,
        preResolvedAuthentication: Bool
    ) {
        self.client = client
        self.userToken = userToken
        self.featureRequestId = featureRequestId
        self.featureRequestTitle = featureRequestTitle
        _isAuthenticated = State(initialValue: preResolvedAuthentication)
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if loadState.isLoading {
                        ProgressView()
                            .padding(.top, 32)
                    } else if let loadError = loadState.loadError {
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

    func commentRow(_ comment: FeatureRequestComment) -> some View {
        let display = comment.displayModel
        let row = HStack(alignment: .top, spacing: 12) {
            if display.isModerated {
                moderatedAvatar
            } else {
                commentAvatar(for: comment)
            }

            VStack(alignment: .leading, spacing: 4) {
                if display.isModerated {
                    moderatedHeader(for: display)
                } else {
                    authorHeader(for: comment)
                }

                replyTag(for: display)

                Text(display.displayBody)
                    .font(.subheadline)
                    .foregroundStyle(display.isModerated ? .secondary : .primary)
                    .italic(display.isModerated)

                if Self.showsReplyButton(canReply: display.canReply, isAuthenticated: isAuthenticated) {
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

    @ViewBuilder
    private var composeArea: some View {
        switch composePresentation {
        case .unavailable:
            EmptyView()
        case .composer:
            composerForm
        case .signInRequired:
            signedOutNotice
        }
    }

    /// The compose-footer branch for the current state (and view-level tests).
    var composePresentation: ComposeAreaPresentation {
        Self.composeAreaPresentation(
            isCommentsUnavailable: isCommentsUnavailable,
            isAuthenticated: isAuthenticated
        )
    }

    private var composerForm: some View {
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
                    .accessibilityLabel(Self.cancelReplyAccessibilityLabel())
                }
            }

            // BUG-18: the count appears once the body nears its cap.
            intakeCharacterCounter(draft.body, limit: IntakeTextLimits.maxCommentLength)

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
                .accessibilityLabel(Self.submitAccessibilityLabel())
            }
        }
        .padding(16)
        .background(.background)
    }

    private var signedOutNotice: some View {
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

    private var canSubmit: Bool {
        !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        IntakeTextLimits.overLimitField(in: draft) == nil
    }

    @MainActor
    private func loadComments() async {
        let generation = loadState.startLoading()
        // The defer (not a trailing assignment) resets `isLoading`: a
        // cancelled load (dismissal, restart for another request) returns
        // early and must still leave the spinner (CONC-4).
        defer { loadState.finishLoading(generation: generation) }
        // The compose-area and reply gates track the resolved access verdict,
        // re-read on every load so a sign-in or sign-out while the thread is
        // presented is picked up (BUG-24). Session verdict, not load data: a
        // superseded load still records the latest answer.
        isAuthenticated = await client.resolveAuthenticatedAccess()
        isCommentsUnavailable = false
        do {
            let fetched = try await client.fetchComments(featureRequestId: featureRequestId)
            // A superseded load (pull-to-refresh racing the initial task,
            // retry taps stacking up) must not clobber the newer run's
            // comments.
            guard loadState.isCurrent(generation: generation) else { return }
            comments = fetched
        } catch {
            // A cancelled load never reached a verdict — keep the currently
            // rendered comments. A superseded run must not write either;
            // both leave the surface to the surviving load.
            guard loadState.isCurrent(generation: generation), !error.isSdkCancellation else { return }
            if let clientError = error as? FeedbackClientError, case .commentsUnavailable = clientError {
                isCommentsUnavailable = true
            }
            loadState.loadError = FriendlyError.message(for: error)
        }
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
            draft.clearReplyTarget()
        } catch {
            guard !error.isSdkCancellation else { return }
            if Self.invalidatesReplyTarget(for: error) {
                // The server rejected the stale reply target (#237): clear
                // it so the next submit succeeds as a top-level comment.
                draft.clearReplyTarget()
            }
            submitError = FriendlyError.message(for: error)
        }
    }
}

// MARK: - Row presentation

extension CommentsView {
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
    private func moderatedHeader(for display: CommentDisplayModel) -> some View {
        HStack {
            Spacer()
            if let date = display.createdAtDate {
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
            // AvatarView is accessibility-hidden, so the button has no
            // content to derive a name from — label it directly.
            .accessibilityLabel(
                Self.viewProfileAccessibilityLabel(
                    authorName: comment.authorName ?? CupThreadStrings.tr("cupthread.features.anonymous")
                )
            )
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

    enum ReplyTagPresentation: Equatable, Sendable {
        case profileButton(clerkId: String, authorName: String)
        case label(authorName: String)
        case none
    }

    static func replyTagPresentation(for display: CommentDisplayModel) -> ReplyTagPresentation {
        guard let replyTo = display.replyToAuthorName else {
            return .none
        }
        if let clerkId = display.replyToClerkId, display.canOpenReplyToProfile, !display.isModerated {
            return .profileButton(clerkId: clerkId, authorName: replyTo)
        }
        return .label(authorName: replyTo)
    }

    @ViewBuilder
    func replyTag(for display: CommentDisplayModel) -> some View {
        switch Self.replyTagPresentation(for: display) {
        case .profileButton(let clerkId, let authorName):
            Button {
                selectedProfileUserId = clerkId
            } label: {
                Text("@\(authorName)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.viewProfileAccessibilityLabel(authorName: authorName))
        case .label(let authorName):
            Text("@\(authorName)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(display.isModerated ? .secondary : Color.accentColor)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func replyButton(for comment: FeatureRequestComment) -> some View {
        let targetAuthor = comment.authorName ?? CupThreadStrings.tr("cupthread.features.anonymous")
        Button {
            guard !comment.isModerated else { return }
            draft.parentId = comment.id
            draft.replyToAuthorName = targetAuthor
            draft.replyToClerkId = comment.authorClerkId
        } label: {
            Text(CupThreadStrings.tr("cupthread.comments.reply"))
                .font(.caption.weight(.medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
        .accessibilityLabel(Self.replyAccessibilityLabel(targetAuthor: targetAuthor))
    }
}

// MARK: - Reply-target recovery & accessibility helpers

extension CommentsView {
    /// Whether a failed comment submission means the reply target is stale
    /// (HTTP 400 `invalid_parent`): the parent was hidden, soft-deleted, or
    /// is not on this feature request by the time the reply was submitted.
    /// The composer clears its reply target so a retry posts a top-level
    /// comment instead of re-failing on the same stale parent.
    nonisolated static func invalidatesReplyTarget(for error: Error) -> Bool {
        guard let clientError = error as? FeedbackClientError else { return false }
        if case .invalidParent = clientError { return true }
        return false
    }

    nonisolated static func submitAccessibilityLabel() -> String {
        CupThreadStrings.tr("cupthread.comments.submit")
    }

    nonisolated static func cancelReplyAccessibilityLabel() -> String {
        CupThreadStrings.tr("cupthread.comments.cancel_reply")
    }

    nonisolated static func replyAccessibilityLabel(targetAuthor: String) -> String {
        CupThreadStrings.tr("cupthread.comments.reply_to_author", targetAuthor)
    }

    nonisolated static func viewProfileAccessibilityLabel(authorName: String) -> String {
        CupThreadStrings.tr("cupthread.comments.view_profile_of", authorName)
    }
}
