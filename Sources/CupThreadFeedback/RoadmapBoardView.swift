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
    @State private var isLoading = true
    /// True once the first load finished (success or failure). Later reloads —
    /// e.g. search-driven — keep showing content instead of flashing skeletons.
    @State private var hasLoadedOnce = false
    @State private var loadError: String?
    @State private var selectedGroupID: String?
    @State private var searchText = ""
    /// Transient notice for a failed reload whose groups stay on screen
    /// (a reload failure never wipes already-rendered content).
    @State private var reloadNotice: String?

    /// The query actually sent to the server, trimmed to match the throttle's
    /// duplicate detection.
    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
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
    }

    public var body: some View {
        Group {
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
        .task(id: trimmedSearchText) {
            guard !trimmedSearchText.isEmpty else {
                // Plain listing: the backend does not rate-limit it, so no
                // debounce or throttle admission is needed.
                await load()
                return
            }
            // Debounce keystrokes: each change restarts this task, cancelling
            // the previous sleep before it triggers a server call. The shared
            // throttle then spaces query-bearing fetches below the server's
            // 30/min per-IP search budget and skips duplicate queries.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            guard await client.searchThrottle.waitForAdmission(key: "roadmap|\(trimmedSearchText)") else { return }
            await load()
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
            isLoading: isLoading,
            hasLoadedOnce: hasLoadedOnce,
            loadError: loadError,
            searchText: searchText,
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
                        RoadmapCard(item: item, highlightQuery: searchText)
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
            HStack(alignment: .top, spacing: 16) {
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
                        ColumnCard(group: group, highlightQuery: searchText)
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
                            RoadmapCard(item: item, highlightQuery: searchText)
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
        if searchText.isEmpty {
            ContentUnavailableView {
                Label(CupThreadStrings.tr("cupthread.roadmap.no_columns_title"), systemImage: "square.grid.3x3")
            } description: {
                Text(CupThreadStrings.tr("cupthread.roadmap.no_columns_description"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Centers a full-height state view inside the pager's layout slot.
    private func stateContainer<V: View>(_ content: V) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor
    private func load() async {
        isLoading = true
        loadError = nil
        reloadNotice = nil
        defer {
            isLoading = false
            hasLoadedOnce = true
        }
        do {
            // The board needs complete data — grouping a single page would
            // silently truncate every column once the app outgrows the
            // server's page size — so page through with a wide page size and
            // let ``collectAllRequests`` stop at the real end of the result
            // set. Columns load independently and concurrently.
            async let columns = client.fetchColumns()
            let boardClient = client
            let boardUserToken = userToken
            let query = trimmedSearchText.isEmpty ? nil : trimmedSearchText
            let requests = try await collectAllRequests { cursor in
                try await boardClient.fetchFeatureRequests(
                    userToken: boardUserToken,
                    limit: 200,
                    query: query,
                    cursor: cursor
                )
            }
            groups = makeGroups(columns: try await columns, requests: requests)
        } catch {
            if let clientError = error as? FeedbackClientError, case .rateLimited = clientError {
                await client.searchThrottle.enterCooldown()
            }
            switch SearchReloadOutcome.outcome(for: error, hasExistingContent: !groups.isEmpty) {
            case .inlineNotice(let message):
                reloadNotice = message
            case .fullScreenError(let message):
                loadError = message
            }
        }
    }
}

// MARK: - Column chip (iPhone pager selector)

private struct ColumnChip: View {
    let name: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                Text(count, format: .number)
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.35) : Color.clear,
                    lineWidth: 1
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(CupThreadStrings.columnAccessibilityLabel(name: name, count: count))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Column card (regular-width board layout)

private struct ColumnCard: View {
    let group: RoadmapGroup
    var highlightQuery: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ColumnHeader(
                name: group.name,
                count: group.requests.count,
                style: StageStyle.forColumn(group.column)
            )

            if group.requests.isEmpty {
                Text(CupThreadStrings.tr("cupthread.roadmap.empty_card"))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                ForEach(group.requests) { item in
                    RoadmapCard(item: item, highlightQuery: highlightQuery)
                }
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CupThreadStrings.columnAccessibilityLabel(name: group.name, count: group.requests.count))
    }
}

// MARK: - Roadmap card

private struct RoadmapCard: View {
    let item: FeatureRequestItem
    var highlightQuery: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HighlightedText(text: item.title, query: highlightQuery)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)

            if !item.description.isEmpty {
                HighlightedText(text: item.description, query: highlightQuery)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 8) {
                if let version = item.versionLabel {
                    CapsuleBadge(icon: "tag", text: version, tint: .secondary)
                }

                if !item.recentCommenters.isEmpty {
                    HStack(spacing: -6) {
                        ForEach(Array(item.recentCommenters.prefix(3).enumerated()), id: \.offset) { index, commenter in
                            AvatarView(url: commenter.avatarUrl, size: 16)
                                .zIndex(Double(3 - index))
                        }
                        if item.hasMoreCommenters {
                            Text("···")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityLabel(CupThreadStrings.tr("cupthread.features.recent_commenters_accessibility"))
                }

                Spacer(minLength: 8)
                VoteCountBadge(count: item.voteCount, hasVoted: item.hasVoted)
            }
        }
        .requestCard()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Empty column placeholder

private struct EmptyColumnView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(CupThreadStrings.tr("cupthread.roadmap.empty_column"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(CupThreadStrings.tr("cupthread.roadmap.empty_column_description"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}
