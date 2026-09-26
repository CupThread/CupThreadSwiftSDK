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

    @State private var entries: [ChangelogEntry] = []
    @State private var isLoading = true
    /// True once the first load finished. Later reloads keep showing content
    /// instead of flashing skeletons.
    @State private var hasLoadedOnce = false
    @State private var loadError: String?
    @State private var isSubscribePresented = false
    /// The remembered subscription email; drives the entry-point copy.
    @State private var subscribedEmail: String?
    @Environment(\.sdkAppConfig) private var sdkAppConfig

    private var isChangelogPermitted: Bool {
        changelogLoadPlan(config: sdkAppConfig) == .load
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
    }

    public var body: some View {
        Group {
            if !isChangelogPermitted {
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
            if isChangelogPermitted {
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
                subscribedEmail = subscriptionStore.subscribedEmail()
            }
        }
        .refreshable {
            guard isChangelogPermitted else { return }
            await loadEntries()
        }
        .task {
            guard isChangelogPermitted else {
                isLoading = false
                hasLoadedOnce = true
                return
            }
            subscribedEmail = subscriptionStore.subscribedEmail()
            await loadEntries()
        }
        .sdkSurface(client: client, feature: .changelog)
    }

    // MARK: Content

    private var cardScroll: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if isLoading && !hasLoadedOnce {
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
                    SubscribeFooterCard(subscribedEmail: subscribedEmail) {
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
            if isLoading && !hasLoadedOnce {
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

    private var subscribeEntryTitle: String {
        subscribedEmail == nil
            ? CupThreadStrings.tr("cupthread.whatsnew.subscribe_button")
            : "Manage Emails"
    }

    private var subscribeEntryIcon: String {
        subscribedEmail == nil ? "envelope" : "envelope.open"
    }

    // MARK: Actions

    @MainActor
    private func loadEntries() async {
        guard changelogLoadPlan(config: sdkAppConfig) == .load else {
            isLoading = false
            hasLoadedOnce = true
            return
        }
        isLoading = true
        loadError = nil
        defer {
            isLoading = false
            hasLoadedOnce = true
        }
        do {
            guard let fetched = try await loadChangelogEntries(client: client, config: sdkAppConfig) else {
                return
            }
            entries = fetched
        } catch {
            // A cancelled load (dismissal, superseded restart) never reached
            // a verdict — keep the currently rendered entries.
            guard !error.isSdkCancellation else { return }
            loadError = FriendlyError.message(for: error)
        }
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
    let subscribedEmail: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: subscribedEmail == nil ? "envelope" : "envelope.open.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    if let subscribedEmail {
                        Text(CupThreadStrings.tr("cupthread.whatsnew.emails_on"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(CupThreadStrings.tr(
                            "cupthread.whatsnew.emails_on_destination", subscribedEmail
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
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
        .accessibilityLabel(subscribedEmail == nil
            ? CupThreadStrings.tr("cupthread.whatsnew.subscribe_accessibility")
            : CupThreadStrings.tr("cupthread.whatsnew.emails_on_accessibility", subscribedEmail ?? ""))
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
