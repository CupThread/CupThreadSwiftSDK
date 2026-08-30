import SwiftUI

// MARK: - Board model

/// Groups feature requests under their board column (by `columnId`).
/// Requests without a column land in a trailing "Other" group so nothing is dropped.
struct RoadmapGroup: Identifiable, Equatable {
    let column: BoardColumn?
    let requests: [FeatureRequestItem]

    var id: String { column?.id ?? "uncategorized" }
    var name: String { column?.name ?? CupThreadStrings.tr("cupthread.roadmap.column_other") }
}

@MainActor
private func makeGroups(columns: [BoardColumn], requests: [FeatureRequestItem]) -> [RoadmapGroup] {
    var byColumn = [String?: [FeatureRequestItem]]()
    for request in requests {
        byColumn[request.columnId, default: []].append(request)
    }
    var groups = columns.map { column in
        RoadmapGroup(column: column, requests: byColumn[column.id] ?? [])
    }
    if let uncategorized = byColumn[nil], !uncategorized.isEmpty {
        groups.append(RoadmapGroup(column: nil, requests: uncategorized))
    }
    return groups
}

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

    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

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
        .task(id: searchText) {
            // Debounce keystrokes: each change restarts this task, cancelling
            // the previous sleep before it triggers a server call.
            if !searchText.isEmpty {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            }
            await load()
        }
        .sdkSurface(client: client, feature: .roadmap)
    }

    /// While searching, columns without matches are hidden so the pager only
    /// shows relevant columns.
    private var visibleGroups: [RoadmapGroup] {
        searchText.isEmpty ? groups : groups.filter { !$0.requests.isEmpty }
    }

    // MARK: iPhone — sticky column chips + paged full-width lists

    private var pagedBoard: some View {
        VStack(spacing: 0) {
            if isLoading && !hasLoadedOnce {
                ScrollView {
                    SkeletonCardList()
                        .padding(16)
                }
            } else if let loadError {
                stateContainer(
                    LoadErrorView(message: loadError) {
                        await load()
                    }
                )
            } else if visibleGroups.isEmpty {
                stateContainer(emptyState)
            } else {                columnChips
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
                if isLoading && !hasLoadedOnce {
                    ForEach(0..<3, id: \.self) { _ in
                        SkeletonColumn()
                    }
                } else if let loadError {
                    LoadErrorView(message: loadError) {
                        await load()
                    }
                    .frame(maxWidth: .infinity)
                } else if groups.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity)
                } else {
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
            if isLoading && !hasLoadedOnce {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                LoadErrorView(message: loadError) {
                    await load()
                }
                .frame(maxWidth: .infinity)
            } else if groups.isEmpty {
                emptyState
            } else {
                ForEach(visibleGroups) { group in
                    Section(group.name) {
                        ForEach(group.requests) { item in
                            RoadmapCard(item: item, highlightQuery: searchText)
                                #if !os(tvOS)
                                .listRowSeparator(.hidden)
                                #endif
                        }
                        if group.requests.isEmpty {
                            Text("Nothing here yet.")
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
                Label("No Roadmap Yet", systemImage: "square.grid.3x3")
            } description: {
                Text("The team hasn't published any roadmap columns.")
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
        defer {
            isLoading = false
            hasLoadedOnce = true
        }
        do {
            async let columns = client.fetchColumns()
            async let requests = client.fetchFeatureRequests(
                userToken: userToken,
                query: searchText.isEmpty ? nil : searchText
            )
            groups = makeGroups(columns: try await columns, requests: try await requests.requests)
        } catch {
            loadError = error.localizedDescription
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
        .accessibilityLabel("Column \(name), \(count) items")
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
                Text("Nothing here yet.")
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
        .accessibilityLabel("Column \(group.name), \(group.requests.count) items")
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
            Text("Nothing here yet")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Items appear here as they move to this stage.")
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
