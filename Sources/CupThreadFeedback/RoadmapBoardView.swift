import SwiftUI

// MARK: - RoadmapBoardView

/// A native roadmap board grouped by public columns.
///
/// Layout adapts per device: iPhone shows a sticky chip bar with a full-width
/// paged list (swipe horizontally to change column); iPad, macOS, and visionOS
/// show the horizontal board; tvOS shows focus-friendly sections.
///
/// Cards are informational (title, description, version, vote count); voting
/// happens in `FeatureRequestsView`, matching the web surface.
public struct RoadmapBoardView: View {
    public let client: FeedbackClient
    public let userToken: String

    @State private var groups: [RoadmapGroup] = []
    /// First-load lifecycle and stale-write generation tracking (issue #274).
    @State private var loadState = RoadmapBoardLoadState()
    @State private var selectedGroupID: String?
    @State private var searchText = ""
    /// The search query that produced the currently loaded roadmap groups.
    @State private var lastExecutedQuery = ""
    /// Deduplicates admission-denial notices so repeated keystrokes during
    /// cooldown do not continuously re-trigger or restart the notice banner.
    @State private var hasEmittedAdmissionNotice = false
    /// Transient notice for a failed reload whose groups stay on screen
    /// (a reload failure never wipes already-rendered content).
    @State private var reloadNotice: String?
    /// Whether a request sent right now could carry the signed-in identity's
    /// bearer token (resolved on every load — issue #297). `false` until the
    /// first load resolved it, so an undecided verdict never renders the
    /// permission placeholder for a signed-in user.
    @State private var isAuthenticated = false
    /// Whether `isAuthenticated` has been resolved at least once. Before that,
    /// a locked-down config must not produce a permission verdict: the board
    /// keeps its loading skeleton instead.
    @State private var hasResolvedAuthentication = false
    /// The server answered `401 authentication_required` on a fetch whose
    /// preflight passed (e.g. the token expired between the check and the
    /// send): the permission placeholder replaces the board.
    @State private var rejectedByServer = false
    @Environment(\.sdkAppConfig) private var sdkAppConfig

    private var isRoadmapPermitted: Bool {
        roadmapLoadPlan(
            config: sdkAppConfig,
            supportsAuthentication: isAuthenticated
        ) == .load
    }

    /// Whether the permission verdict can be decided: either anonymous roadmap
    /// access is allowed (the verdict cannot depend on authentication) or the
    /// resolved access state is in.
    private var isRoadmapVerdictResolved: Bool {
        hasResolvedAuthentication || (sdkAppConfig?.allowsAnonymousRoadmap ?? true)
    }

    /// Whether the board must render the permission placeholder: the
    /// preflight denied a locked-down board, or the server's 401 overrode a
    /// permitted one.
    private var isRoadmapPermissionBlocked: Bool {
        isSurfacePermissionBlocked(
            verdictResolved: isRoadmapVerdictResolved,
            permitted: isRoadmapPermitted,
            rejectedByServer: rejectedByServer
        )
    }

    /// The query actually sent to the server, trimmed to match the throttle's
    /// duplicate detection.
    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Restarts the load lifecycle whenever the permission verdict or the
    /// search query changes (issue #274). Keyed on the search text alone, the
    /// task never re-ran when `sdkAppConfig` (or resolved authentication)
    /// flipped the verdict, so a denied→permitted config transition left the
    /// board on its first-load skeleton forever. A verdict-stable config
    /// refresh keeps the key — and the in-flight load — unchanged.
    private var loadTaskKey: String {
        makeRoadmapLoadTaskKey(isRoadmapPermitted: isRoadmapPermitted, trimmedSearchText: trimmedSearchText)
    }

    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// Creates the roadmap board.
    /// - Parameters:
    ///   - client: The shared ``FeedbackClient``.
    ///   - userToken: Anonymous token identifying this user; drives
    ///     `hasVoted`/`isOwnRequest` badges on the cards.
    ///   - initialSearchText: Search text pre-filled before first load.
    public init(client: FeedbackClient, userToken: String, initialSearchText: String = "") {
        self.client = client
        self.userToken = userToken
        _searchText = State(initialValue: initialSearchText)
        _lastExecutedQuery = State(initialValue: "")
    }

    /// Internal initializer for tests and previews with preloaded groups.
    init(
        client: FeedbackClient,
        userToken: String,
        initialSearchText: String = "",
        initialGroups: [RoadmapGroup]?
    ) {
        self.client = client
        self.userToken = userToken
        _searchText = State(initialValue: initialSearchText)
        _lastExecutedQuery = State(initialValue: initialSearchText)
        if let initialGroups {
            _groups = State(initialValue: initialGroups)
            _loadState = State(initialValue: RoadmapBoardLoadState(isLoading: false, hasLoadedOnce: true))
        }
    }

    public var body: some View {
        Group {
            if isRoadmapPermissionBlocked {
                SdkPermissionDeniedView(
                    titleKey: "cupthread.permission.roadmap_title",
                    descriptionKey: "cupthread.permission.roadmap_description"
                )
            } else {
            #if os(tvOS)
            boardList
            #elseif os(iOS)
            if horizontalSizeClass == .compact {
                pagedBoard
            } else {
                boardScroll
            }
            #else
            boardScroll
            #endif
            }
        }
        .navigationTitle(CupThreadStrings.tr("cupthread.roadmap.title"))
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $searchText, prompt: Text(CupThreadStrings.tr("cupthread.roadmap.search_prompt")))
        .overlay(alignment: .top) {
            if let reloadNotice {
                InlineNoticeBanner(message: reloadNotice)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .task(id: loadTaskKey) {
            await resolveAuthenticationAccess()
            guard isRoadmapPermitted else {
                settlePermissionDeniedState()
                return
            }
            guard !trimmedSearchText.isEmpty else {
                // Plain listing: unrate-limited, so no debounce/throttle.
                hasEmittedAdmissionNotice = false
                await load()
                return
            }
            // Debounce keystrokes: each change restarts this task, cancelling
            // the previous sleep; the shared throttle spaces query-bearing
            // fetches below the 30/min per-IP budget and skips duplicates.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let admitted = await client.searchThrottle.waitForAdmission(key: "roadmap|\(trimmedSearchText)")
            guard admitted else {
                guard let outcome = SearchAdmissionOutcome.outcome(
                    isCancelled: Task.isCancelled,
                    hasExistingContent: !groups.isEmpty
                ) else { return }
                switch outcome {
                case .inlineNotice(let message):
                    if !hasEmittedAdmissionNotice {
                        reloadNotice = message
                        hasEmittedAdmissionNotice = true
                    }
                case .fullScreenError(let message):
                    loadState.loadError = message
                }
                return
            }
            // Admission already recorded this query's fetch slot (CONC-9).
            await load(alreadyAdmitted: true)
        }
        .task(id: reloadNotice) {
            guard reloadNotice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                reloadNotice = nil
            }
        }
        .sdkSurface(client: client, feature: .roadmap)
    }

    /// The single source of truth for what the board renders; every layout
    /// switches over it so loading, error, empty, and content states agree.
    private var displayState: RoadmapBoardDisplayState {
        makeBoardDisplayState(
            isLoading: loadState.isLoading,
            hasLoadedOnce: loadState.hasLoadedOnce,
            loadError: loadState.loadError,
            searchText: lastExecutedQuery,
            groups: groups
        )
    }

    /// While searching, columns without matches are hidden so the pager only
    /// shows relevant columns. Derived from ``displayState`` so the filter
    /// lives in exactly one place.
    private var visibleGroups: [RoadmapGroup] {
        if case let .board(groups) = displayState { return groups }
        return []
    }

    // MARK: iPhone — sticky column chips + paged full-width lists

    private var pagedBoard: some View {
        VStack(spacing: 0) {
            switch displayState {
            case .loading:
                ScrollView {
                    SkeletonCardList()
                        .padding(16)
                }
            case .error(let message):
                stateContainer(
                    LoadErrorView(message: message) {
                        await load()
                    }
                )
            case .emptySearch, .emptyBoard:
                stateContainer(emptyState)
            case .board:
                columnChips
                pager
            }
        }
    }

    private var columnChips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(visibleGroups) { group in
                        ColumnChip(
                            name: group.name,
                            count: group.requests.count,
                            isSelected: selectedGroupID == group.id
                        ) {
                            withAnimation(.snappy(duration: 0.25)) {
                                selectedGroupID = group.id
                            }
                        }
                        .id(group.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .onChange(of: selectedGroupID) {
                guard let selectedGroupID else { return }
                withAnimation(.snappy(duration: 0.2)) {
                    proxy.scrollTo(selectedGroupID, anchor: .center)
                }
            }
        }
    }

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(visibleGroups) { group in
                    columnPage(group)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $selectedGroupID)
        .onChange(of: visibleGroups, initial: true) {
            if selectedGroupID == nil || !visibleGroups.contains(where: { $0.id == selectedGroupID }) {
                selectedGroupID = visibleGroups.first?.id
            }
        }
    }

    private func columnPage(_ group: RoadmapGroup) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ColumnHeader(
                    name: group.name,
                    count: group.requests.count,
                    style: StageStyle.forColumn(group.column)
                )
                .padding(.top, 4)

                if group.requests.isEmpty {
                    EmptyColumnView()
                } else {
                    ForEach(group.requests) { item in
                        RoadmapCard(item: item, highlightQuery: lastExecutedQuery)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .refreshable { await load() }
        .containerRelativeFrame(.horizontal)
    }

    // MARK: iPad / macOS / visionOS — horizontal board cards

    private var boardScroll: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 16) {
                switch displayState {
                case .loading:
                    ForEach(0..<3, id: \.self) { _ in
                        SkeletonColumn()
                    }
                case .error(let message):
                    LoadErrorView(message: message) {
                        await load()
                    }
                    .frame(maxWidth: .infinity)
                case .emptySearch, .emptyBoard:
                    emptyState
                        .frame(maxWidth: .infinity)
                case .board(let visibleGroups):
                    ForEach(visibleGroups) { group in
                        ColumnCard(group: group, highlightQuery: lastExecutedQuery)
                    }
                }
            }
            .padding(16)
            .frame(minHeight: 200, alignment: .top)
        }
    }

    // tvOS: sections stack vertically for focus-driven navigation.
    private var boardList: some View {
        List {
            switch displayState {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error(let message):
                LoadErrorView(message: message) {
                    await load()
                }
                .frame(maxWidth: .infinity)
            case .emptySearch, .emptyBoard:
                emptyState
            case .board(let visibleGroups):
                ForEach(visibleGroups) { group in
                    Section(group.name) {
                        ForEach(group.requests) { item in
                            RoadmapCard(item: item, highlightQuery: lastExecutedQuery)
                                #if !os(tvOS)
                                .listRowSeparator(.hidden)
                                #endif
                        }
                        if group.requests.isEmpty {
                            Text(CupThreadStrings.tr("cupthread.roadmap.empty_card"))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .refreshable { await load() }
    }

    // MARK: Shared states

    @ViewBuilder
    private var emptyState: some View {
        if lastExecutedQuery.isEmpty {
            ContentUnavailableView {
                Label(CupThreadStrings.tr("cupthread.roadmap.no_columns_title"), systemImage: "square.grid.3x3")
            } description: {
                Text(CupThreadStrings.tr("cupthread.roadmap.no_columns_description"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView.search(text: lastExecutedQuery)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Actions

extension RoadmapBoardView {
    /// Centers a full-height state view inside the pager's layout slot.
    private func stateContainer<V: View>(_ content: V) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor
    private func load(alreadyAdmitted: Bool = false) async {
        await resolveAuthenticationAccess()
        guard isRoadmapPermitted else {
            settlePermissionDeniedState()
            return
        }
        rejectedByServer = false
        let generation = loadState.startLoading()
        reloadNotice = nil
        defer { loadState.finishLoading(generation: generation) }
        do {
            // The board needs complete data — grouping a single page would
            // silently truncate every column once the app outgrows the
            // server's page size — so page through with a wide page size and
            // let ``collectAllRequests`` stop at the real end of the result
            // set. Columns load independently and concurrently.
            let query = trimmedSearchText.isEmpty ? nil : trimmedSearchText
            if let loaded = try await loadRoadmapGroups(
                client: client,
                userToken: userToken,
                query: query,
                config: sdkAppConfig,
                skipInitialAdmissionRecord: alreadyAdmitted
            ) {
                // A newer load or a permission denial owns the board now.
                guard loadState.isCurrent(generation: generation) else { return }
                groups = loaded
                lastExecutedQuery = trimmedSearchText
                hasEmittedAdmissionNotice = false
            }
        } catch {
            await handleLoadFailure(error, generation: generation)
        }
    }

    /// Classifies and presents a failed load for `generation`. A cancelled
    /// load (keystroke restart, dismissal) never reached a verdict and a
    /// superseded run must not write — so both keep the board untouched
    /// (issue #274). A server permission rejection swaps in the placeholder;
    /// every other failure becomes a transient notice over existing content
    /// or a full-screen error.
    @MainActor
    private func handleLoadFailure(_ error: Error, generation: Int) async {
        guard let outcome = SearchReloadOutcome.outcome(for: error, hasExistingContent: !groups.isEmpty) else { return }
        guard loadState.isCurrent(generation: generation) else { return }
        if isSdkPermissionRejection(error) {
            // The preflight passed but the server still answered 401 — the
            // token expired (or was revoked) between the check and the
            // send. The signed-out permission placeholder replaces the
            // board instead of the generic error state (issue #297).
            rejectedByServer = true
            return
        }
        if let clientError = error as? FeedbackClientError, case .rateLimited = clientError {
            await client.searchThrottle.enterCooldown()
            // The rate-limit notice is emitted below; mark it so repeated
            // keystrokes during the cooldown cannot re-trigger it (#269).
            hasEmittedAdmissionNotice = true
        }
        switch outcome {
        case .inlineNotice(let message):
            reloadNotice = message
        case .fullScreenError(let message):
            loadState.handleFailure(message: message, generation: generation)
        }
    }

    /// Settles the lifecycle on the denied path (issue #274): the board can
    /// no longer be stranded on its first-load skeleton if the body leaves
    /// the permission placeholder without a task restart, and the generation
    /// bump discards the writes of any in-flight permitted load — including
    /// unstructured ones (pull-to-refresh) that SwiftUI's task cancellation
    /// does not reach.
    private func settlePermissionDeniedState() {
        loadState.settlePermissionDenied()
        reloadNotice = nil
    }

    /// Resolves whether the client can act as the signed-in user right now and
    /// records it for the permission verdict. Runs on every load: the user can
    /// sign in or out while the board is presented.
    @MainActor
    private func resolveAuthenticationAccess() async {
        isAuthenticated = await client.resolveAuthenticatedAccess()
        hasResolvedAuthentication = true
    }
}
