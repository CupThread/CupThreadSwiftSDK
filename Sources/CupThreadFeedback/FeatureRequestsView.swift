#if canImport(UIKit)
import UIKit
#endif
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
    /// Load lifecycle (in-flight flag, first-verdict flag, generation). Only a
    /// completed verdict of the newest, non-cancelled load resolves it — a
    /// cancelled or superseded load writes nothing (issue #286).
    @State private var loadState = FeatureRequestsLoadState()
    @State private var loadError: String?
    @State private var isComposePresented = false
    @State private var showSubmittedBanner = false
    @State private var activeSheet: FeatureRequestsActiveSheet?

    @State private var searchText = ""
    /// Version-filter options and their load outcome (issue #285): a failed
    /// load keeps the menu reachable with a retry instead of disabling it.
    @State private var versionFilterState = VersionFilterLoadState()
    @State private var selectedVersionID: String?
    @State private var isLoadingNextPage = false
    /// Failure of the latest cursor-page ("load more") attempt. Distinct from
    /// `loadError`, which is the initial-load failure: the loaded pages stay
    /// on screen and the load-more row turns into an explicit retry.
    @State private var pageError: String?
    @State private var voteNotice: String?
    /// Transient notice for a failed reload whose results stay on screen
    /// (a reload failure never wipes already-rendered content).
    @State private var reloadNotice: String?
    /// Per-item counters incremented once a vote is *confirmed* by the
    /// server; drives the pill's success bounce/haptic so a reverted
    /// (failed) vote never fires success cues.
    @State private var voteSuccessPulses: [String: Int] = [:]
    /// Whether a request sent right now could carry the signed-in identity's
    /// bearer token. Resolved at the start of every load (issue #297) — the
    /// user can sign in or out while the list is presented. Fail-closed until
    /// then: list content only renders after the first load anyway.
    @State private var isAuthenticated = false

    @Environment(\.sdkAppConfig) private var sdkAppConfig

    /// Whether the compose sheet and toolbar should offer the composer rather
    /// than the denial placeholder: anonymous submission is allowed by the
    /// console, or the client can produce a bearer token for the current user
    /// (`nil` config fails open; the server stays authoritative).
    private var canCompose: Bool {
        (sdkAppConfig?.allowsAnonymousFeedback ?? true) || isAuthenticated
    }

    var items: [FeatureRequestItem] {
        listState.items
    }

    private var votingIds: Set<String> {
        listState.votingIds
    }

    // Lifecycle accessors for the rendering branches (and view-level tests).
    var isLoading: Bool { loadState.isLoading }
    var hasLoadedOnce: Bool { loadState.hasLoadedOnce }
    var loadGeneration: Int { loadState.loadGeneration }
    /// Whether the post-submit success banner is presented (issue #270).
    var isSubmittedBannerVisible: Bool { showSubmittedBanner }

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
        // Post-submit confirmation as a top overlay (issue #270), mirroring
        // RoadmapBoardView's reloadNotice: it composes above both layouts and
        // every content state, so an empty or failed post-submit reload never
        // replaces the success banner — and tvOS's list, which has no inline
        // banner slot, still shows the confirmation.
        .overlay(alignment: .top) {
            featureRequestsSubmittedBanner(isVisible: showSubmittedBanner)
        }
        .toolbar {
            versionFilterToolbarItem
            composeToolbarItem
        }
        .sheet(isPresented: $isComposePresented) {
            if canCompose {
                FeatureRequestComposeView(client: client, userToken: userToken) {
                    isComposePresented = false
                    withAnimation(.snappy(duration: 0.3)) {
                        showSubmittedBanner = true
                    }
                    Task { await loadFeatureRequests() }
                }
            } else {
                FeatureRequestDenialSheet {
                    isComposePresented = false
                }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            NavigationStack {
                switch sheet {
                case .comments(let item):
                    CommentsView(
                        client: client,
                        userToken: userToken,
                        featureRequestId: item.id,
                        featureRequestTitle: item.title
                    )
                case .profile(let userId):
                    UserProfileView(client: client, userId: userId)
                }
            }
        }
        .refreshable { await loadFeatureRequests() }
        // Re-keyed on the anonymous-roadmap verdict (issue #285): versions
        // answers 401/403 while anonymous reads are disabled; re-attempt on
        // config transitions instead of staying stuck on the first failure.
        .task(id: sdkAppConfig?.allowsAnonymousRoadmap) {
            await loadVersions()
        }
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
        .autoClearNotice($voteNotice)
        .autoClearNotice($reloadNotice)
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
                            successPulse: voteSuccessPulses[item.id, default: 0],
                            onSelectCard: { activeSheet = .comments(item) },
                            onSelectUser: { activeSheet = .profile($0) },
                            appConfig: sdkAppConfig,
                            supportsAuthentication: isAuthenticated
                        ) {
                            Task { await toggleVoteOptimistic(for: item) }
                        }
                    }
                    if listState.hasMorePages {
                        LoadMoreRow(
                            pageError: pageError,
                            isLoadingNextPage: isLoadingNextPage,
                            onRetry: { Task { await loadNextPage() } },
                            onNearEnd: { Task { await loadNextPageIfEligible() } }
                        )
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
                if let voteNotice {
                    InlineNoticeBanner(message: voteNotice)
                }
                if let reloadNotice {
                    InlineNoticeBanner(message: reloadNotice)
                }
                ForEach(items) { item in
                    FeatureRequestCard(
                        item: item,
                        highlightQuery: searchText,
                        isVoteInFlight: votingIds.contains(item.id),
                        successPulse: voteSuccessPulses[item.id, default: 0],
                        onSelectCard: { activeSheet = .comments(item) },
                        onSelectUser: { activeSheet = .profile($0) },
                        appConfig: sdkAppConfig,
                        supportsAuthentication: isAuthenticated
                    ) {
                        Task { await toggleVoteOptimistic(for: item) }
                    }
                    #if !os(tvOS)
                    .listRowSeparator(.hidden)
                    #endif
                }
                if listState.hasMorePages {
                    LoadMoreRow(
                        pageError: pageError,
                        isLoadingNextPage: isLoadingNextPage,
                        onRetry: { Task { await loadNextPage() } },
                        onNearEnd: { Task { await loadNextPageIfEligible() } }
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .refreshable { await loadFeatureRequests() }
    }

    private var emptyState: some View {
        FeatureRequestsEmptyState(
            searchText: searchText,
            canCompose: canCompose
        ) {
            isComposePresented = true
        }
    }

    private var emptyStateText: String {
        featureRequestsEmptyStateText(searchText: searchText)
    }

    // MARK: Toolbar

    private var versionFilterToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            VersionFilterMenu(selectedVersionID: $selectedVersionID, state: versionFilterState, onRetry: { Task { await loadVersions() } })
        }
    }

    private var composeToolbarItem: some ToolbarContent {
        featureRequestsComposeToolbar(canCompose: canCompose) {
            isComposePresented = true
        }
    }

    // MARK: Actions

    @MainActor
    private func loadVersions() async {
        versionFilterState.loadStarted()
        do {
            versionFilterState.loadFinished(try await client.fetchVersions())
        } catch {
            versionFilterState.loadFailed(error)
        }
    }

    @MainActor
    private func loadFeatureRequests() async {
        isAuthenticated = await client.resolveAuthenticatedAccess()
        let generationAtStart = loadState.startLoading()
        loadError = nil
        reloadNotice = nil
        pageError = nil
        defer {
            // Only a completed verdict of the newest, non-cancelled load may
            // resolve the lifecycle. A cancelled or superseded load never
            // reached one: clearing `isLoading` or setting `hasLoadedOnce`
            // here would fabricate the empty state while the replacement load
            // is still in flight (issue #286).
            loadState.finishLoading(generation: generationAtStart, wasCancelled: Task.isCancelled)
        }
        do {
            let result = try await client.fetchFeatureRequests(
                userToken: userToken,
                versionId: selectedVersionID,
                query: trimmedSearchText.isEmpty ? nil : trimmedSearchText
            )
            // A newer replacing load (search/version change, pull-to-refresh)
            // superseded this one — applying its page would render the older
            // filter's results.
            guard loadGeneration == generationAtStart else { return }
            listState.applyPage(result, replacesExisting: true)
        } catch {
            guard loadGeneration == generationAtStart,
                  !Task.isCancelled,
                  let outcome = SearchReloadOutcome.outcome(for: error, hasExistingContent: !items.isEmpty)
            else { return }
            if let clientError = error as? FeedbackClientError, case .rateLimited = clientError {
                await client.searchThrottle.enterCooldown()
            }
            switch outcome {
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
        let generationAtStart = loadGeneration
        isLoadingNextPage = true
        defer { isLoadingNextPage = false }
        do {
            let result = try await client.fetchFeatureRequests(
                userToken: userToken,
                versionId: selectedVersionID,
                query: trimmedSearchText.isEmpty ? nil : trimmedSearchText,
                cursor: cursor
            )
            // A newer replacing load (search/version change, pull-to-refresh)
            // superseded this cursor page — appending it would mix filters.
            guard loadGeneration == generationAtStart else { return }
            pageError = nil
            listState.applyPage(result, replacesExisting: false)
        } catch {
            guard loadGeneration == generationAtStart, !error.isSdkCancellation else { return }
            if let clientError = error as? FeedbackClientError, case .rateLimited = clientError {
                await client.searchThrottle.enterCooldown()
            }
            // Deep paging is best-effort; surface the failure at the end of
            // the list without disturbing the loaded pages.
            pageError = FriendlyError.message(for: error)
        }
    }

    /// Loads the next page when the load-more row scrolls into view, unless a
    /// failed attempt is waiting for the explicit retry tap.
    @MainActor
    private func loadNextPageIfEligible() async {
        guard listState.hasMorePages, !isLoadingNextPage, pageError == nil else { return }
        await loadNextPage()
    }

    @MainActor
    private func toggleVoteOptimistic(for item: FeatureRequestItem) async {
        guard !FeatureVoteGate.isActionDisabled(
            isOwnRequest: item.isOwnRequest,
            config: sdkAppConfig,
            supportsAuthentication: isAuthenticated
        ) else {
            return
        }
        guard let (originalVoted, originalCount) = listState.applyOptimisticVote(for: item.id) else {
            return
        }

        do {
            let result = try await client.toggleVote(featureRequestId: item.id, userToken: userToken)
            listState.reconcileVoteSuccess(itemId: item.id, voted: result.voted, voteCount: result.voteCount)
            // Success cues fire here, on the confirmed state — never on the
            // optimistic flip nor on a reverted failure.
            voteSuccessPulses[item.id, default: 0] += 1
        } catch {
            listState.reconcileVoteFailure(
                itemId: item.id,
                originalVoted: originalVoted,
                originalCount: originalCount
            )
            let notice = VoteFailureNotice.notice(for: error)
            guard notice != .silent else { return }
            voteNotice = notice.message
            announceVoteFailure(notice.message)
        }
    }

    /// VoiceOver announcement for a failed vote; the visual banner alone is
    /// easy to miss between the flip and the revert.
    private func announceVoteFailure(_ message: String) {
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: message)
        #endif
    }
}

// MARK: - Test support

extension FeatureRequestsView {
    /// Internal initializer for tests with custom list and load state.
    init(
        client: FeedbackClient,
        userToken: String,
        listState: FeatureRequestsListState,
        loadState: FeatureRequestsLoadState,
        showsSubmittedBanner: Bool = false
    ) {
        self.client = client
        self.userToken = userToken
        _listState = State(initialValue: listState)
        _loadState = State(initialValue: loadState)
        _showSubmittedBanner = State(initialValue: showsSubmittedBanner)
    }
}
