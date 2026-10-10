// swiftlint:disable file_length
// One surface per file: the view's @State must stay file-private, so the
// body is organized by MARK sections rather than split across files to fit
// the size budget (same policy as the oversized test suites, .swiftlint.yml).
import SwiftUI

// MARK: - WhatsNewView

/// The public "What's New" surface fed by the app's changelog.
///
/// Entries are listed newest-first with a version badge, friendly date, body
/// text, and chips for the feature requests that shipped. iPhone, iPad, macOS,
/// and visionOS show a card list; tvOS uses a focus-friendly `List`. A toolbar
/// button (plus a footer entry point) opens the email subscription sheet,
/// which reflects the remembered subscription state
/// (see `ChangelogSubscriptionStore`) instead of always offering a blank form.
public struct WhatsNewView: View {
    public let client: FeedbackClient
    public let userToken: String
    /// Optional console configuration override (previews/tests); `nil` falls
    /// back to the `sdkAppConfig` environment value.
    let configOverride: PublicAppConfig?

    @State private var state: WhatsNewViewState
    @State private var isSubscribePresented = false
    /// The remembered subscription with its double-opt-in phase; drives the
    /// entry-point copy (issue #273).
    @State private var subscription: ChangelogSubscriptionRecord?
    /// Whether a request sent right now could carry the signed-in identity's
    /// bearer token (resolved on every load — issue #297). `false` until the
    /// first load resolved it, so an undecided verdict never renders the
    /// permission placeholder for a signed-in user.
    @State private var isAuthenticated = false
    /// Whether `isAuthenticated` has been resolved at least once. Before that,
    /// a locked-down config must not produce a permission verdict: the surface
    /// keeps its loading skeleton instead.
    @State private var hasResolvedAuthentication = false
    /// The server answered `401 authentication_required` on a fetch whose
    /// preflight passed (e.g. the token expired between the check and the
    /// send): the permission placeholder replaces the list.
    @State private var rejectedByServer = false
    @Environment(\.sdkAppConfig) private var sdkAppConfig

    private var activeConfig: PublicAppConfig? {
        configOverride ?? sdkAppConfig
    }

    var entries: [ChangelogEntry] { state.entries }
    var isLoading: Bool { state.isLoading }
    var hasLoadedOnce: Bool { state.hasLoadedOnce }
    var loadError: String? { state.loadError }
    var loadGeneration: Int { state.loadGeneration }

    private var isChangelogPermitted: Bool {
        changelogLoadPlan(
            config: activeConfig,
            supportsAuthentication: isAuthenticated
        ) == .load
    }

    /// Whether the permission verdict can be decided: either anonymous
    /// changelog access is allowed (the verdict cannot depend on
    /// authentication) or the resolved access state is in.
    private var isChangelogVerdictResolved: Bool {
        hasResolvedAuthentication || (activeConfig?.allowsAnonymousChangelog ?? true)
    }

    /// Whether the surface must render the permission placeholder: the
    /// preflight denied a locked-down console, or the server's 401 overrode a
    /// permitted one.
    private var isChangelogPermissionBlocked: Bool {
        isSurfacePermissionBlocked(
            verdictResolved: isChangelogVerdictResolved,
            permitted: isChangelogPermitted,
            rejectedByServer: rejectedByServer
        )
    }

    /// Restarts the load lifecycle whenever the config's anonymous-changelog
    /// switch transitions (issues #265, #364). Keyed on the resolved permission
    /// verdict, the task cancelled and restarted itself: its first act —
    /// `resolveAuthenticationAccess()` — flips `isAuthenticated`, which flipped
    /// the verdict and therefore the key mid-flight (issue #364). The switch is
    /// external to the task (the task cannot mutate it), so a locked-down
    /// changelog resolves authentication inside one stable-key run and loads —
    /// or settles denied — exactly once. A switch-stable config refresh keeps
    /// the key — and the in-flight load — unchanged.
    var loadTaskKey: Bool {
        makeChangelogLoadTaskKey(
            allowsAnonymousChangelog: activeConfig?.allowsAnonymousChangelog ?? true
        )
    }

    private var subscriptionStore: ChangelogSubscriptionStore {
        ChangelogSubscriptionStore(appKey: client.configuration.appKey)
    }

    /// Creates the "What's New" view.
    /// - Parameters:
    ///   - client: The shared ``FeedbackClient``.
    ///   - userToken: Anonymous token identifying this user; links email
    ///     subscriptions made from this view to the end-user identity.
    public init(client: FeedbackClient, userToken: String) {
        self.client = client
        self.userToken = userToken
        self.configOverride = nil
        self._state = State(initialValue: WhatsNewViewState())
    }

    /// Internal initializer for tests with custom initial state.
    ///
    /// - Parameters:
    ///   - configOverride: Console configuration override; `nil` falls back to
    ///     the `sdkAppConfig` environment value.
    ///   - preResolvedAuthentication: Injects the resolved access verdict for
    ///     view-level tests — `nil` leaves the verdict unsettled so the surface
    ///     resolves in `.task` (the production presentation), while
    ///     `true`/`false` inject a settled verdict without awaiting `.task`.
    init(
        client: FeedbackClient,
        userToken: String,
        state: WhatsNewViewState = WhatsNewViewState(),
        configOverride: PublicAppConfig? = nil,
        preResolvedAuthentication: Bool? = nil
    ) {
        self.client = client
        self.userToken = userToken
        self.configOverride = configOverride
        self._state = State(initialValue: state)
        self._isAuthenticated = State(initialValue: preResolvedAuthentication ?? false)
        self._hasResolvedAuthentication = State(initialValue: preResolvedAuthentication != nil)
    }

    public var body: some View {
        Group {
            if isChangelogPermissionBlocked {
                SdkPermissionDeniedView(
                    titleKey: "cupthread.permission.changelog_title",
                    descriptionKey: "cupthread.permission.changelog_description"
                )
            } else {
                #if os(tvOS)
                tvList
                #else
                cardScroll
                #endif
            }
        }
        .navigationTitle(CupThreadStrings.tr("cupthread.whatsnew.title"))
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if isChangelogPermitted, !isChangelogPermissionBlocked {
                subscribeToolbarItem
            }
        }
        .sheet(isPresented: $isSubscribePresented) {
            ChangelogSubscribeView(client: client, userToken: userToken)
        }
        .onChange(of: isSubscribePresented) { _, isPresented in
            // Re-read the remembered subscription when the sheet closes so the
            // entry points reflect a subscription made inside it.
            if !isPresented {
                subscription = subscriptionStore.subscriptionRecord()
            }
        }
        .refreshable {
            guard isChangelogPermitted else { return }
            await loadEntries()
        }
        .task(id: loadTaskKey) {
            await resolveAuthenticationAccess()
            guard isChangelogPermitted else {
                state.handlePermissionDenied(generation: state.loadGeneration)
                return
            }
            subscription = subscriptionStore.subscriptionRecord()
            await loadEntries()
        }
        .sdkSurface(client: client, feature: .changelog)
    }

    // MARK: Content

    private var cardScroll: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if isLoading && (!hasLoadedOnce || entries.isEmpty) {
                    SkeletonCardList()
                } else if let loadError {
                    LoadErrorView(message: loadError) {
                        await loadEntries()
                    }
                    .padding(.top, 32)
                } else {
                    if entries.isEmpty {
                        emptyState
                            .padding(.top, 48)
                            .padding(.bottom, 8)
                    }
                    ForEach(entries) { entry in
                        ChangelogEntryCard(entry: entry)
                    }
                    SubscribeFooterCard(subscription: subscription) {
                        isSubscribePresented = true
                    }
                }
            }
            .padding(16)
        }
    }

    // tvOS: plain list rows keep the focus engine happy.
    private var tvList: some View {
        List {
            if isLoading && (!hasLoadedOnce || entries.isEmpty) {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if let loadError {
                LoadErrorView(message: loadError) {
                    await loadEntries()
                }
                .frame(maxWidth: .infinity)
            } else {
                if entries.isEmpty {
                    Text(CupThreadStrings.tr("cupthread.whatsnew.no_updates_tv"))
                        .foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    ChangelogEntryCard(entry: entry)
                        #if !os(tvOS)
                        .listRowSeparator(.hidden)
                        #endif
                }
                Button {
                    isSubscribePresented = true
                } label: {
                    Label(subscribeEntryTitle, systemImage: subscribeEntryIcon)
                }
            }
        }
        .refreshable { await loadEntries() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(CupThreadStrings.tr("cupthread.whatsnew.no_updates_title"), systemImage: "sparkles")
        } description: {
            Text(CupThreadStrings.tr("cupthread.whatsnew.no_updates_desc"))
        }
    }

    // MARK: Toolbar

    private var subscribeToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                isSubscribePresented = true
            } label: {
                Label(subscribeEntryTitle, systemImage: subscribeEntryIcon)
            }
            .accessibilityHint(CupThreadStrings.tr("cupthread.whatsnew.subscribe_desc"))
        }
    }

    // MARK: Entry-point labels

    /// Entry-point title for the remembered address regardless of phase —
    /// the pre-#273 mapping kept for callers that only hold a bare email
    /// (treated as confirmed, matching the legacy-storage migration).
    nonisolated static func subscribeEntryTitle(subscribedEmail: String?) -> String {
        subscribedEmail == nil
            ? CupThreadStrings.tr("cupthread.whatsnew.subscribe_button")
            : CupThreadStrings.tr("cupthread.whatsnew.emails_on")
    }

    /// Entry-point title by double-opt-in phase: a pending subscription
    /// names the outstanding confirmation instead of claiming emails are on.
    nonisolated static func subscribeEntryTitle(record: ChangelogSubscriptionRecord?) -> String {
        switch record?.state {
        case .confirmed:
            CupThreadStrings.tr("cupthread.whatsnew.emails_on")
        case .pending:
            CupThreadStrings.tr("cupthread.whatsnew.pending_title")
        case nil:
            CupThreadStrings.tr("cupthread.whatsnew.subscribe_button")
        }
    }

    var subscribeEntryTitle: String {
        Self.subscribeEntryTitle(record: subscription)
    }

    private var subscribeEntryIcon: String {
        switch subscription?.state {
        case .pending: "envelope.open.badge.clock"
        case .confirmed: "envelope.open"
        case nil: "envelope"
        }
    }

    // MARK: Actions

    @MainActor
    func loadEntries() async {
        await resolveAuthenticationAccess()
        guard isChangelogPermitted else {
            state.handlePermissionDenied(generation: state.loadGeneration)
            return
        }
        rejectedByServer = false
        let generationAtStart = state.startLoading()
        defer {
            state.finishLoading(generation: generationAtStart)
        }
        do {
            guard let fetched = try await loadChangelogEntries(client: client, config: activeConfig) else {
                state.handlePermissionDenied(generation: generationAtStart)
                return
            }
            state.handleSuccess(entries: fetched, generation: generationAtStart)
        } catch {
            // A cancelled load (dismissal, superseded restart) never reached
            // a verdict — keep the currently rendered entries.
            guard !error.isSdkCancellation else { return }
            if isSdkPermissionRejection(error) {
                // The preflight passed but the server still answered 401 —
                // the token expired between the check and the send. The
                // signed-out permission placeholder replaces the list instead
                // of the generic error state (issue #297).
                rejectedByServer = true
                return
            }
            state.handleFailure(error: error, generation: generationAtStart)
        }
    }

    /// Resolves whether the client can act as the signed-in user right now and
    /// records it for the permission verdict. Runs on every load: the user can
    /// sign in or out while the surface is presented.
    @MainActor
    private func resolveAuthenticationAccess() async {
        isAuthenticated = await client.resolveAuthenticatedAccess()
        hasResolvedAuthentication = true
    }
}

// MARK: - Entry card

struct ChangelogEntryCard: View {
    let entry: ChangelogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            Text(entry.title)
                .font(.subheadline.weight(.semibold))

            if !entry.body.isEmpty {
                MarkdownText(content: entry.body)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !entry.linkedRequests.isEmpty {
                linkedRequestChips
            }
        }
        .requestCard()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var header: some View {
        if entry.versionLabel != nil || entry.publishedAtDate != nil {
            HStack(alignment: .firstTextBaseline) {
                if let version = entry.versionLabel {
                    CapsuleBadge(icon: "tag", text: version, tint: .accentColor)
                        .accessibilityLabel(
                            CupThreadStrings.tr("cupthread.whatsnew.version_accessibility", version)
                        )
                }
                Spacer(minLength: 8)
                if let date = entry.publishedAtDate {
                    Text(date, format: .dateTime.month(.abbreviated).day().year())
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var linkedRequestChips: some View {
        FlowLayout(spacing: 6) {
            ForEach(entry.linkedRequests) { request in
                CapsuleBadge(icon: "checkmark.circle.fill", text: request.title, tint: .green)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            CupThreadStrings.tr(
                "cupthread.whatsnew.shipped_requests_accessibility",
                entry.linkedRequests.map(\.title).joined(separator: ", ")
            )
        )
    }
}

// MARK: - Subscribe footer (card list entry point)

private struct SubscribeFooterCard: View {
    let subscription: ChangelogSubscriptionRecord?
    let action: () -> Void

    private var icon: String {
        switch subscription?.state {
        case .pending: "envelope.open.badge.clock.fill"
        case .confirmed: "envelope.open.fill"
        case nil: "envelope"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    switch subscription?.state {
                    case .confirmed:
                        Text(CupThreadStrings.tr("cupthread.whatsnew.emails_on"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(CupThreadStrings.tr(
                            "cupthread.whatsnew.emails_on_destination", subscription?.email ?? ""
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .pending:
                        Text(CupThreadStrings.tr("cupthread.whatsnew.pending_title"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(CupThreadStrings.tr(
                            "cupthread.whatsnew.pending_destination", subscription?.email ?? ""
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case nil:
                        Text(CupThreadStrings.tr("cupthread.whatsnew.get_emails"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(CupThreadStrings.tr("cupthread.whatsnew.get_emails_caption"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .requestCard()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch subscription?.state {
        case .confirmed:
            CupThreadStrings.tr(
                "cupthread.whatsnew.emails_on_accessibility", subscription?.email ?? ""
            )
        case .pending:
            CupThreadStrings.tr(
                "cupthread.whatsnew.pending_accessibility", subscription?.email ?? ""
            )
        case nil:
            CupThreadStrings.tr("cupthread.whatsnew.subscribe_accessibility")
        }
    }
}

// MARK: - Flow layout

/// Wrapping layout so variable-width chips flow across lines instead of
/// truncating (used for shipped-request badges).
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var size = CGSize.zero
        var rowX: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let item = subview.sizeThatFits(.unspecified)
            if rowX > 0, rowX + item.width > maxWidth {
                size.height += rowHeight + spacing
                rowX = 0
                rowHeight = 0
            }
            rowX += item.width + spacing
            rowHeight = max(rowHeight, item.height)
            size.width = max(size.width, rowX - spacing)
        }
        size.height += rowHeight
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var point = CGPoint(x: bounds.minX, y: bounds.minY)
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let item = subview.sizeThatFits(.unspecified)
            if point.x > bounds.minX, point.x + item.width > bounds.maxX {
                point.x = bounds.minX
                point.y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: point, anchor: .topLeading, proposal: .unspecified)
            point.x += item.width + spacing
            rowHeight = max(rowHeight, item.height)
        }
    }
}
