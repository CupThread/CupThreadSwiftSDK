import SwiftUI

// MARK: - Request card

struct FeatureRequestCard: View {
    let item: FeatureRequestItem
    var highlightQuery: String = ""
    let isVoteInFlight: Bool
    /// Increments once per server-confirmed vote on this item; drives the
    /// vote pill's success bounce and haptic (a reverted vote fires none).
    var successPulse: Int = 0
    var onSelectCard: (() -> Void)?
    var onSelectUser: ((String) -> Void)?
    /// Console configuration used to preflight-disable the vote pill when
    /// anonymous voting is off. `nil` fails open (own-request still disables).
    var appConfig: PublicAppConfig?
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
                        .accessibilityLabel(
                            CupThreadStrings.tr("cupthread.features.stage_accessibility", item.stageName)
                        )

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
            .contentShape(Rectangle())
            .onTapGesture {
                onSelectCard?()
            }

            VotePill(
                voteCount: item.voteCount,
                hasVoted: item.hasVoted,
                isInFlight: isVoteInFlight,
                successPulse: successPulse,
                isDisabled: FeatureVoteGate.isActionDisabled(
                    isOwnRequest: item.isOwnRequest,
                    config: appConfig
                ),
                disabledHintKey: FeatureVoteGate.hintKey(
                    isOwnRequest: item.isOwnRequest,
                    config: appConfig
                )
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
                requesterLabel

                if !item.recentCommenters.isEmpty {
                    commentersStack
                }

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

    @ViewBuilder
    private var requesterLabel: some View {
        if let clerkId = item.requesterClerkId {
            Button {
                onSelectUser?(clerkId)
            } label: {
                HStack(spacing: 6) {
                    AvatarView(url: item.requesterAvatarUrl, size: 20)
                    Text(item.requesterName.flatMap { $0.isEmpty ? nil : $0 } ?? CupThreadStrings.tr("cupthread.features.anonymous"))
                        .lineLimit(1)
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 6) {
                AvatarView(url: item.requesterAvatarUrl, size: 20)
                Text(item.requesterName.flatMap { $0.isEmpty ? nil : $0 } ?? CupThreadStrings.tr("cupthread.features.anonymous"))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var commentersStack: some View {
        HStack(spacing: -6) {
            ForEach(Array(item.recentCommenters.prefix(3).enumerated()), id: \.offset) { index, commenter in
                if let clerkId = commenter.clerkUserId {
                    Button {
                        onSelectUser?(clerkId)
                    } label: {
                        AvatarView(url: commenter.avatarUrl, size: 18)
                    }
                    .buttonStyle(.plain)
                    .zIndex(Double(3 - index))
                } else {
                    AvatarView(url: commenter.avatarUrl, size: 18)
                        .zIndex(Double(3 - index))
                }
            }
            if item.hasMoreCommenters {
                Text("···")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityLabel(CupThreadStrings.tr("cupthread.features.recent_commenters_accessibility"))
    }
}
