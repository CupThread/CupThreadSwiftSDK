import SwiftUI

// MARK: - FeatureRequestsView

/// Browse, vote on, and submit feature requests.
///
/// iPhone, iPad, macOS, and visionOS show a card list with optimistic voting;
/// tvOS uses a focus-friendly `List`. Voting on your own requests is disabled,
/// matching the web surface.
public struct FeatureRequestsView: View {
    public let client: FeedbackClient
    public let userToken: String

    @State private var items: [FeatureRequestItem] = []
    @State private var isLoading = true
    /// True once the first load finished. Later reloads (search, version filter)
    /// keep showing content instead of flashing skeletons.
    @State private var hasLoadedOnce = false
    @State private var loadError: String?
    @State private var isComposePresented = false
    @State private var showSubmittedBanner = false

    @State private var searchText = ""
    @State private var versions: [AppVersion] = []
    @State private var selectedVersionID: String?

    // Tracks which item IDs have an in-flight vote request (prevents double-taps).
    @State private var votingIds: Set<String> = []

    /// Creates the feature requests list.
    /// - Parameters:
    ///   - client: The shared ``FeedbackClient``.
    ///   - userToken: Anonymous token identifying this user; drives
    ///     `hasVoted` state, own-request detection, and voting.
    ///   - autoPresentCompose: Shows the submission sheet immediately on first
    ///     appearance — e.g. when the view is opened from a "Request a feature"
    ///     deep link.
    ///   - initialSearchText: Search text pre-filled before first load.
    public init(
        client: FeedbackClient,
        userToken: String,
        autoPresentCompose: Bool = false,
        initialSearchText: String = ""
    ) {
        self.client = client
        self.userToken = userToken
        _isComposePresented = State(initialValue: autoPresentCompose)
        _searchText = State(initialValue: initialSearchText)
    }

    /// Any change restarts the task; while the user is typing, the leading sleep
    /// debounces server calls (a restart cancels the previous sleep).
    private var filterKey: String {
        "\(searchText)|\(selectedVersionID ?? "")"
    }

    public var body: some View {
        Group {
            #if os(tvOS)
            tvList
            #else
            cardScroll
            #endif
        }
        .navigationTitle(CupThreadStrings.tr("cupthread.features.title"))
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $searchText, prompt: Text(CupThreadStrings.tr("cupthread.features.search_prompt")))
        .toolbar {
            versionFilterToolbarItem
            composeToolbarItem
        }
        .sheet(isPresented: $isComposePresented) {
            FeatureRequestComposeView(client: client, userToken: userToken) {
                isComposePresented = false
                withAnimation(.snappy(duration: 0.3)) {
                    showSubmittedBanner = true
                }
                Task { await loadFeatureRequests() }
            }
        }
        .refreshable { await loadFeatureRequests() }
        .task { await loadVersions() }
        .task(id: filterKey) {
            if !searchText.isEmpty {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            }
            await loadFeatureRequests()
        }
        .task(id: showSubmittedBanner) {
            guard showSubmittedBanner else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                showSubmittedBanner = false
            }
        }
        .sdkSurface(client: client, feature: .featureRequests)
    }

    // MARK: Content

    private var cardScroll: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if isLoading && !hasLoadedOnce {
                    SkeletonCardList()
                } else if let loadError {
                    LoadErrorView(message: loadError) {
                        await loadFeatureRequests()
                    }
                    .padding(.top, 32)
                } else if items.isEmpty {
                    emptyState
                        .padding(.top, 48)
                } else {
                    if showSubmittedBanner {
                        SubmittedBanner()
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    ForEach(items) { item in
                        FeatureRequestCard(
                            item: item,
                            highlightQuery: searchText,
                            isVoteInFlight: votingIds.contains(item.id)
                        ) {
                            Task { await toggleVoteOptimistic(for: item) }
                        }
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
                    await loadFeatureRequests()
                }
                .frame(maxWidth: .infinity)
            } else if items.isEmpty {
                Text(emptyStateText)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    FeatureRequestCard(
                        item: item,
                        highlightQuery: searchText,
                        isVoteInFlight: votingIds.contains(item.id)
                    ) {
                        Task { await toggleVoteOptimistic(for: item) }
                    }
                    #if !os(tvOS)
                    .listRowSeparator(.hidden)
                    #endif
                }
            }
        }
        .refreshable { await loadFeatureRequests() }
    }

    @ViewBuilder
    private var emptyState: some View {
        if searchText.isEmpty {
            ContentUnavailableView {
                Label(CupThreadStrings.tr("cupthread.features.empty_title"), systemImage: "lightbulb")
            } description: {
                Text(CupThreadStrings.tr("cupthread.features.empty_description"))
            } actions: {
                Button(CupThreadStrings.tr("cupthread.features.request_a_feature")) {
                    isComposePresented = true
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView.search(text: searchText)
        }
    }

    private var emptyStateText: String {
        if !searchText.isEmpty {
            return CupThreadStrings.tr("cupthread.features.empty_with_query", searchText)
        }
        return CupThreadStrings.tr("cupthread.features.empty_no_requests")
    }

    // MARK: Toolbar

    private var versionFilterToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker(CupThreadStrings.tr("cupthread.features.version_picker"), selection: $selectedVersionID) {
                    Text(CupThreadStrings.tr("cupthread.features.all_versions")).tag(String?.none)
                    ForEach(versions) { version in
                        Text(version.label).tag(String?.some(version.id))
                    }
                }
            } label: {
                Label(
                    selectedVersionID.flatMap { id in versions.first(where: { $0.id == id })?.label }
                        ?? CupThreadStrings.tr("cupthread.features.all_versions"),
                    systemImage: "line.3.horizontal.decrease.circle"
                )
            }
            .disabled(versions.isEmpty)
            .accessibilityLabel(CupThreadStrings.tr("cupthread.features.filter_by_version"))
        }
    }

    private var composeToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                isComposePresented = true
            } label: {
                Label(CupThreadStrings.tr("cupthread.features.request_a_feature"), systemImage: "plus")
            }
            .accessibilityHint(CupThreadStrings.tr("cupthread.features.request_a_feature_hint"))
        }
    }

    // MARK: Actions

    @MainActor
    private func loadVersions() async {
        versions = (try? await client.fetchVersions()) ?? []
    }

    @MainActor
    private func loadFeatureRequests() async {
        isLoading = true
        loadError = nil
        defer {
            isLoading = false
            hasLoadedOnce = true
        }
        do {
            let result = try await client.fetchFeatureRequests(
                userToken: userToken,
                versionId: selectedVersionID,
                query: searchText.isEmpty ? nil : searchText
            )
            items = result.requests
        } catch {
            loadError = error.localizedDescription
        }
    }

    @MainActor
    private func toggleVoteOptimistic(for item: FeatureRequestItem) async {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              !votingIds.contains(item.id) else { return }

        votingIds.insert(item.id)
        defer { votingIds.remove(item.id) }

        // Apply optimistic update immediately so the UI responds without waiting for the server.
        items[index] = item.withVoteState(
            voted: !item.hasVoted,
            count: item.hasVoted ? item.voteCount - 1 : item.voteCount + 1
        )

        do {
            let result = try await client.toggleVote(featureRequestId: item.id, userToken: userToken)
            // Reconcile with the authoritative server counts (index may shift during an async gap).
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx] = items[idx].withVoteState(voted: result.voted, count: result.voteCount)
            }
        } catch {
            // Revert to the pre-optimistic state on failure.
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx] = item
            }
        }
    }
}

// MARK: - Request card

private struct FeatureRequestCard: View {
    let item: FeatureRequestItem
    var highlightQuery: String = ""
    let isVoteInFlight: Bool
    let vote: () -> Void

    var body: some View {
        let stageStyle = StageStyle.forRequest(item)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HighlightedText(text: item.title, query: highlightQuery)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    CapsuleBadge(icon: stageStyle.icon, text: item.stageName, tint: stageStyle.tint)
                        .accessibilityLabel("Stage: \(item.stageName)")

                    if item.isOwnRequest && !item.approved {
                        CapsuleBadge(icon: "clock", text: CupThreadStrings.tr("cupthread.features.pending_review"), tint: .orange)
                    }

                    if let version = item.versionLabel {
                        CapsuleBadge(icon: "tag", text: version, tint: .secondary)
                    }
                }

                if !item.description.isEmpty {
                    // Searching highlights the raw text so query ranges line up;
                    // otherwise render inline Markdown.
                    Group {
                        if highlightQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            MarkdownText(content: item.description)
                        } else {
                            HighlightedText(text: item.description, query: highlightQuery)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                }

                metaRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VotePill(
                voteCount: item.voteCount,
                hasVoted: item.hasVoted,
                isInFlight: isVoteInFlight,
                isDisabled: item.isOwnRequest
            ) {
                vote()
            }
        }
        .requestCard()
    }

    @ViewBuilder
    private var metaRow: some View {
        if let released = item.releasedVersion {
            CapsuleBadge(icon: "checkmark.seal.fill", text: CupThreadStrings.tr("cupthread.features.released_in", released), tint: .green)
        } else {
            HStack(spacing: 10) {
                Label(
                    item.requesterName.flatMap { $0.isEmpty ? nil : $0 } ?? CupThreadStrings.tr("cupthread.features.anonymous"),
                    systemImage: "person"
                )
                if let date = item.createdAtDate {
                    Label {
                        Text(date, format: .relative(presentation: .named))
                    } icon: {
                        Image(systemName: "clock")
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Submitted banner

private struct SubmittedBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(CupThreadStrings.tr("cupthread.features.submitted_banner"))
                .font(.footnote.weight(.medium))
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Compose sheet

private struct FeatureRequestComposeView: View {
    let client: FeedbackClient
    let userToken: String
    let onSubmitted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = FeatureRequestDraft()
    @State private var isSubmitting = false
    @State private var submitError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(CupThreadStrings.tr("cupthread.feedback.title_label"), text: $draft.title, prompt: Text(CupThreadStrings.tr("cupthread.feedback.short_summary")))
                    TextField(CupThreadStrings.tr("cupthread.feedback.description_label"), text: $draft.description, axis: .vertical)
                        .lineLimit(5...10)
                        .padding(.top, 2)
                } header: {
                    Text(CupThreadStrings.tr("cupthread.feedback.section_feedback"))
                } footer: {
                    Text(CupThreadStrings.tr("cupthread.features.compose_desc_prompt"))
                }

                Section {
                    TextField(CupThreadStrings.tr("cupthread.features.compose_name_prompt"), text: $draft.requesterName)
                } header: {
                    Text(CupThreadStrings.tr("cupthread.feedback.section_contact"))
                } footer: {
                    Text(CupThreadStrings.tr("cupthread.feedback.section_contact_footer"))
                }

                if let submitError {
                    Section {
                        ErrorBanner(message: submitError)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle(CupThreadStrings.tr("cupthread.features.compose_title"))
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 420)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(CupThreadStrings.tr("cupthread.whatsnew.close_button")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? CupThreadStrings.tr("cupthread.features.compose_sending") : CupThreadStrings.tr("cupthread.features.compose_submit")) {
                        Task { await submit() }
                    }
                    .disabled(isSubmitting || !canSubmit)
                }
            }
        }
    }

    private var canSubmit: Bool {
        draft.title.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 &&
        draft.description.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5
    }

    @MainActor
    private func submit() async {
        isSubmitting = true
        submitError = nil
        defer { isSubmitting = false }
        do {
            _ = try await client.submitFeatureRequest(draft, userToken: userToken)
            onSubmitted()
        } catch {
            submitError = error.localizedDescription
        }
    }
}
