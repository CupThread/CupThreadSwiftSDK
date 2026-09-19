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
    /// Failure of the latest cursor-page ("load more") attempt. Distinct from
    /// `loadError`, which is the initial-load failure: the loaded pages stay
    /// on screen and the load-more row turns into an explicit retry.
    @State private var pageError: String?
    /// Bumped by every replacing load (search text, version filter,
    /// pull-to-refresh, submit). A cursor-page response computed for an older
    /// generation is dropped instead of being appended onto the new filter's
    /// results.
    @State private var loadGeneration = 0
    @State private var voteNotice: String?
    /// Transient notice for a failed reload whose results stay on screen
    /// (a reload failure never wipes already-rendered content).
    @State private var reloadNotice: String?
    /// Per-item counters incremented once a vote is *confirmed* by the
    /// server; drives the pill's success bounce/haptic so a reverted
    /// (failed) vote never fires success cues.
    @State private var voteSuccessPulses: [String: Int] = [:]

    @Environment(\.sdkAppConfig) private var sdkAppConfig

    /// Console permission: anonymous feature-request submission is allowed.
    /// `nil` config fails open so a missing environment never hides compose.
    private var allowsAnonymousFeedback: Bool {
        sdkAppConfig?.allowsAnonymousFeedback ?? true
    }

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
            if allowsAnonymousFeedback {
                FeatureRequestComposeView(client: client, userToken: userToken) {
                    isComposePresented = false
                    withAnimation(.snappy(duration: 0.3)) {
                        showSubmittedBanner = true
                    }
                    Task { await loadFeatureRequests() }
                }
            } else {
                NavigationStack {
                    SdkSubmissionDenial.anonymousFeedbackDisabled.featureRequestPlaceholder
                }
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
                            successPulse: voteSuccessPulses[item.id, default: 0],
                            onSelectCard: { selectedItemForComments = item },
                            onSelectUser: { selectedUserIdForProfile = $0 },
                            appConfig: sdkAppConfig
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
                        onSelectCard: { selectedItemForComments = item },
                        onSelectUser: { selectedUserIdForProfile = $0 },
                        appConfig: sdkAppConfig
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
            allowsAnonymousFeedback: allowsAnonymousFeedback
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
            VersionFilterMenu(selectedVersionID: $selectedVersionID, versions: versions)
        }
    }

    private var composeToolbarItem: some ToolbarContent {
        featureRequestsComposeToolbar(allowsAnonymousFeedback: allowsAnonymousFeedback) {
            isComposePresented = true
        }
    }

    // MARK: Actions

    @MainActor
    private func loadVersions() async {
        versions = (try? await client.fetchVersions()) ?? []
    }

    @MainActor
    private func loadFeatureRequests() async {
        loadGeneration += 1
        isLoading = true
        loadError = nil
        reloadNotice = nil
        pageError = nil
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
            guard !Task.isCancelled,
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
        guard !FeatureVoteGate.isActionDisabled(isOwnRequest: item.isOwnRequest, config: sdkAppConfig) else {
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
