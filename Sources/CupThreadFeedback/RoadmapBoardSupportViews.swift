import SwiftUI

// MARK: - RoadmapBoardView support views
//
// Module-internal pieces extracted from RoadmapBoardView.swift to keep the
// surface file within the library file-size budget.

// MARK: - Column chip (iPhone pager selector)

struct ColumnChip: View {
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

struct ColumnCard: View {
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
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 8) {
                        ForEach(group.requests) { item in
                            RoadmapCard(item: item, highlightQuery: highlightQuery)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .topLeading)
        .containerRelativeFrame(.vertical, alignment: .topLeading) { length, _ in
            max(200, length - 32)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CupThreadStrings.columnAccessibilityLabel(name: group.name, count: group.requests.count))
    }
}

// MARK: - Roadmap card

struct RoadmapCard: View {
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

struct EmptyColumnView: View {
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
