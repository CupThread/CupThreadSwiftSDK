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

    @State private var listState = FeatureRequestsListState()
    @State private var isLoading = true
    /// True once the first load finished. Later reloads (search, version filter)
    /// keep showing content instead of flashing skeletons.
    @State private var hasLoadedOnce = false
    @State private var loadError: String?
    @State private var isComposePresented = false
    @State private var showSubmittedBanner = false
    @State private var selectedItemForComments: FeatureRequestItem?
    @State private var selectedUserIdForProfile: String?

    @State private var searchText = ""
    @State private var versions: [AppVersion] = []
    @State private var selectedVersionID: String?
    @State private var isLoadingNextPage = false
    @State private var voteNotice: String?
    /// Transient notice for a failed reload whose results stay on screen
    /// (a reload failure never wipes already-rendered content).
    @State private var reloadNotice: String?

    private var items: [FeatureRequestItem] {
        listState.items
    }

    private var votingIds: Set<String> {
        listState.votingIds
    }

    /// The query actually sent to the server, trimmed to match the throttle's
    /// duplicate detection.
    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
    /// debounces server calls (a restart cancels the previous sleep). The key
    /// is the trimmed query plus the version filter — the identity the shared
    /// search throttle uses for duplicate suppression.
    private var filterKey: String {
        "features|\(trimmedSearchText)|\(selectedVersionID ?? "")"
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
        .sheet(item: $selectedItemForComments) { item in
            NavigationStack {
                CommentsView(
                    client: client,
                    userToken: userToken,
                    featureRequestId: item.id,
                    featureRequestTitle: item.title
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { selectedUserIdForProfile != nil },
            set: { if !$0 { selectedUserIdForProfile = nil } }
        )) {
            if let userId = selectedUserIdForProfile {
                NavigationStack {
                    UserProfileView(client: client, userId: userId)
                }
            }
        }
        .refreshable { await loadFeatureRequests() }
        .task { await loadVersions() }
        .task(id: filterKey) {
            guard !trimmedSearchText.isEmpty else {
                // Plain listing: the backend does not rate-limit it, so no
                // debounce or throttle admission is needed.
                await loadFeatureRequests()
                return
            }
            // Debounce keystrokes: each change restarts this task, cancelling
            // the previous sleep before it triggers a server call. The shared
            // throttle then spaces query-bearing fetches below the server's
            // 30/min per-IP search budget and skips duplicate queries.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            guard await client.searchThrottle.waitForAdmission(key: filterKey) else { return }
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
        .task(id: voteNotice) {
            guard voteNotice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                voteNotice = nil
            }
        }
        .task(id: reloadNotice) {
            guard reloadNotice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                reloadNotice = nil
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
                    if let voteNotice {
                        InlineNoticeBanner(message: voteNotice)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if let reloadNotice {
                        InlineNoticeBanner(message: reloadNotice)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    ForEach(items) { item in
                        FeatureRequestCard(
                            item: item,
                            highlightQuery: searchText,
                            isVoteInFlight: votingIds.contains(item.id),
                            onSelectCard: { selectedItemForComments = item },
                            onSelectUser: { selectedUserIdForProfile = $0 }
                        ) {
                            Task { await toggleVoteOptimistic(for: item) }
                        }
                    }
                    if listState.hasMorePages {
                        loadMoreRow
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
                if let reloadNotice {
                    InlineNoticeBanner(message: reloadNotice)
                }
                ForEach(items) { item in
                    FeatureRequestCard(
                        item: item,
                        highlightQuery: searchText,
                        isVoteInFlight: votingIds.contains(item.id),
                        onSelectCard: { selectedItemForComments = item },
                        onSelectUser: { selectedUserIdForProfile = $0 }
                    ) {
                        Task { await toggleVoteOptimistic(for: item) }
                    }
                    #if !os(tvOS)
                    .listRowSeparator(.hidden)
                    #endif
                }
                if listState.hasMorePages {
                    loadMoreRow
                        .frame(maxWidth: .infinity)
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
            VersionFilterMenu(selectedVersionID: $selectedVersionID, versions: versions)
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

    private var loadMoreRow: some View {
        Button {
            Task { await loadNextPage() }
        } label: {
            HStack(spacing: 8) {
                if isLoadingNextPage {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(CupThreadStrings.tr("cupthread.features.load_more"))
                    .font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(12)
        }
        .buttonStyle(.bordered)
        .disabled(isLoadingNextPage)
        .accessibilityHint(CupThreadStrings.tr("cupthread.features.load_more_hint"))
    }

    @MainActor
    private func loadVersions() async {
        versions = (try? await client.fetchVersions()) ?? []
    }

    @MainActor
    private func loadFeatureRequests() async {
        isLoading = true
        loadError = nil
        reloadNotice = nil
        defer {
            isLoading = false
            hasLoadedOnce = true
        }
        do {
            let result = try await client.fetchFeatureRequests(
                userToken: userToken,
                versionId: selectedVersionID,
                query: trimmedSearchText.isEmpty ? nil : trimmedSearchText
            )
            guard !Task.isCancelled else { return }
            listState.applyPage(result, replacesExisting: true)
        } catch {
            guard !Task.isCancelled else { return }
            if let clientError = error as? FeedbackClientError, case .rateLimited = clientError {
                await client.searchThrottle.enterCooldown()
            }
            switch SearchReloadOutcome.outcome(for: error, hasExistingContent: !items.isEmpty) {
            case .inlineNotice(let message):
                reloadNotice = message
            case .fullScreenError(let message):
                loadError = message
            }
        }
    }

    @MainActor
    private func loadNextPage() async {
        guard !isLoadingNextPage, let cursor = listState.nextCursor else { return }
        isLoadingNextPage = true
        defer { isLoadingNextPage = false }
        do {
            let result = try await client.fetchFeatureRequests(
                userToken: userToken,
                versionId: selectedVersionID,
                query: searchText.isEmpty ? nil : searchText,
                cursor: cursor
            )
            guard !Task.isCancelled else { return }
            listState.applyPage(result, replacesExisting: false)
        } catch {
            guard !Task.isCancelled else { return }
            // Deep paging is best-effort; surface the failure without
            // disturbing the loaded pages.
            voteNotice = error.localizedDescription
        }
    }

    @MainActor
    private func toggleVoteOptimistic(for item: FeatureRequestItem) async {
        guard let (originalVoted, originalCount) = listState.applyOptimisticVote(for: item.id) else {
            return
        }

        do {
            let result = try await client.toggleVote(featureRequestId: item.id, userToken: userToken)
            listState.reconcileVoteSuccess(itemId: item.id, voted: result.voted, voteCount: result.voteCount)
        } catch FeedbackClientError.rateLimited {
            listState.reconcileVoteFailure(
                itemId: item.id,
                originalVoted: originalVoted,
                originalCount: originalCount
            )
            voteNotice = CupThreadStrings.tr("cupthread.features.vote_rate_limited")
        } catch {
            listState.reconcileVoteFailure(
                itemId: item.id,
                originalVoted: originalVoted,
                originalCount: originalCount
            )
        }
    }
}

// MARK: - Version filter menu

private struct VersionFilterMenu: View {
    @Binding var selectedVersionID: String?
    let versions: [AppVersion]

    var body: some View {
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
