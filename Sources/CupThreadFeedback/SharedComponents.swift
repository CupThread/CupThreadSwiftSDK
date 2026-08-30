import SwiftUI

// MARK: - Stage styling

/// Visual treatment (tint + symbol) for a roadmap stage, derived from the board
/// column kind or a request's column slug. Presentation only — never persisted.
struct StageStyle {
    let tint: Color
    let icon: String

    static func forColumn(_ column: BoardColumn?) -> StageStyle {
        guard let column else { return fallback }
        switch column.kind {
        case .done:
            return forSlug("done")
        case .pendingReview:
            return forSlug("review")
        case .normal:
            return forSlug(column.slug)
        }
    }

    static func forRequest(_ item: FeatureRequestItem) -> StageStyle {
        forSlug(item.columnSlug?.lowercased() ?? item.status.lowercased())
    }

    private static func forSlug(_ slug: String) -> StageStyle {
        if slug.contains("done") || slug.contains("shipped") || slug.contains("released") {
            return StageStyle(tint: .green, icon: "checkmark.circle.fill")
        }
        if slug.contains("progress") || slug.contains("doing") || slug.contains("building") {
            return StageStyle(tint: .orange, icon: "wrench.and.screwdriver.fill")
        }
        if slug.contains("review") || slug.contains("consider") {
            return StageStyle(tint: .blue, icon: "eye.circle.fill")
        }
        if slug.contains("planned") || slug.contains("next") || slug.contains("upcoming") || slug.contains("backlog") {
            return StageStyle(tint: .blue, icon: "calendar.circle.fill")
        }
        return fallback
    }

    private static var fallback: StageStyle {
        StageStyle(tint: .accentColor, icon: "square.stack.3d.up.fill")
    }
}

// MARK: - Badges

/// Small tinted capsule used for stage, version, and status chips.
struct CapsuleBadge: View {
    let icon: String?
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2)
            }
            Text(text)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.10), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Vote controls

/// Light haptics when the vote state flips. `SensoryFeedback.impact(weight:)`
/// is gated to visionOS 26 while the package deploys to visionOS 1, so the
/// modifier no-ops on earlier visionOS.
private struct LightHapticModifier: ViewModifier {
    let trigger: Bool

    func body(content: Content) -> some View {
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 26.0, *) {
            content.sensoryFeedback(.impact(weight: .light), trigger: trigger)
        } else {
            content
        }
    }
}

/// Interactive vote toggle: 44pt-tall pill with a monospaced digit count.
/// Bounces its arrow and fires light haptics on state change.
struct VotePill: View {
    let voteCount: Int
    let hasVoted: Bool
    let isInFlight: Bool
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: hasVoted ? "arrowtriangle.up.fill" : "arrowtriangle.up")
                    .font(.footnote.weight(.semibold))
                    .symbolEffect(.bounce, value: hasVoted)
                Text(voteCount, format: .number)
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            .frame(width: 44)
            .frame(minHeight: 44)
            .padding(.horizontal, 8)
            .foregroundStyle(hasVoted ? Color.accentColor : Color.secondary)
            .background(
                hasVoted ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08),
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(
                    hasVoted ? Color.accentColor.opacity(0.35) : Color.clear,
                    lineWidth: 1
                )
            }
            .opacity(isInFlight ? 0.5 : 1)
            .animation(.easeOut(duration: 0.15), value: isInFlight)
        }
        .buttonStyle(.plain)
        .disabled(isInFlight || isDisabled)
        .modifier(LightHapticModifier(trigger: hasVoted))
        .accessibilityLabel(
            hasVoted
                ? CupThreadStrings.tr("cupthread.features.vote_remove_accessibility", Int64(voteCount))
                : CupThreadStrings.tr("cupthread.features.vote_add_accessibility", Int64(voteCount))
        )
        .accessibilityHint(isDisabled ? CupThreadStrings.tr("cupthread.features.vote_own_hint") : CupThreadStrings.tr("cupthread.features.vote_toggle_hint"))
    }
}

/// Read-only vote count shown on roadmap cards (voting happens in the
/// feature requests list, matching the web surface).
struct VoteCountBadge: View {
    let count: Int
    let hasVoted: Bool

    var body: some View {
        CapsuleBadge(
            icon: hasVoted ? "arrowtriangle.up.fill" : "arrowtriangle.up",
            text: "\(count)",
            tint: hasVoted ? .accentColor : .secondary
        )
        .accessibilityLabel(CupThreadStrings.tr("cupthread.features.vote_count_accessibility", Int64(count), hasVoted ? CupThreadStrings.tr("cupthread.features.vote_including_yours") : ""))
    }
}

// MARK: - Column header

/// Icon-in-tinted-square + name + item count, shared by the iPhone page header
/// and the regular-width board column card.
struct ColumnHeader: View {
    let name: String
    let count: Int
    let style: StageStyle

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: style.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(style.tint, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                Text("\(count) \(count == 1 ? "item" : "items")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Column \(name), \(count) items")
    }
}

// MARK: - Card background

private struct RequestCardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
            }
    }
}

extension View {
    /// Shared card treatment for request/feedback content across SDK views.
    func requestCard() -> some View {
        modifier(RequestCardBackground())
    }
}

// MARK: - Skeletons

/// Shape-based placeholder card shown while the first load is in flight.
struct SkeletonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Capsule().fill(.secondary.opacity(0.22)).frame(width: 190, height: 13)
            Capsule().fill(.secondary.opacity(0.14)).frame(maxWidth: .infinity).frame(height: 11)
            Capsule().fill(.secondary.opacity(0.14)).frame(width: 150, height: 11)
            HStack {
                Capsule().fill(.secondary.opacity(0.18)).frame(width: 64, height: 20)
                Spacer(minLength: 0)
                Capsule().fill(.secondary.opacity(0.18)).frame(width: 48, height: 28)
            }
        }
        .requestCard()
        .accessibilityHidden(true)
    }
}

struct SkeletonCardList: View {
    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                SkeletonCard()
            }
        }
    }
}

/// Board-column-shaped skeleton for the regular-width horizontal layout.
struct SkeletonColumn: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.secondary.opacity(0.22))
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(.secondary.opacity(0.22)).frame(width: 110, height: 12)
                    Capsule().fill(.secondary.opacity(0.14)).frame(width: 64, height: 8)
                }
                Spacer(minLength: 0)
            }
            SkeletonCard()
            SkeletonCard()
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .accessibilityHidden(true)
    }
}

// MARK: - Inline error banner

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.leading)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.red)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.red.opacity(0.2), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Date helpers

extension FeatureRequestItem {
    /// Parsed `createdAt`, accepting plain and fractional-second ISO-8601.
    var createdAtDate: Date? {
        if let date = try? Date(createdAt, strategy: Self.fractionalISO) {
            return date
        }
        return try? Date(createdAt, strategy: .iso8601)
    }

    private static let fractionalISO = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}
