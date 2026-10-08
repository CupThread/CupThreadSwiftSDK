import SwiftUI

/// One-line character counter for a free-text intake field approaching its
/// client-side cap (BUG-18). The composers show it once the field reaches
/// 80% of its cap; past the cap it turns red and the submission gate
/// disables sending. The cap itself is enforced by the gates — this row
/// explains it and names the field's budget, so an over-limit paste is
/// actionable instead of failing server-side with file-flavored copy.
struct CharacterCounterRow: View {
    let length: Int
    let limit: Int

    /// Whether the counter is worth showing: the field has reached 80% of
    /// its cap. Below that the field is unremarkable and the row stays
    /// hidden, so ordinary entries gain no visual noise.
    static func isVisible(length: Int, limit: Int) -> Bool {
        guard limit > 0 else { return false }
        return Double(length) >= Double(limit) * 0.8
    }

    private var isOverLimit: Bool {
        length > limit
    }

    var body: some View {
        Text(CupThreadStrings.tr("cupthread.common.character_count", length, limit))
            .font(.caption2)
            .foregroundStyle(isOverLimit ? Color.red : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                CupThreadStrings.tr("cupthread.common.character_count_accessibility", length, limit)
            )
    }
}

extension View {
    /// Renders the intake field's character-count row (BUG-18) for `text`
    /// against `limit`: hidden until the field reaches 80% of its cap, red
    /// past it. The composers' `Form` sections pass `styledAsFormRow: true`
    /// for the transparent-row insets; plain surfaces (the comment composer)
    /// leave it `false`.
    @ViewBuilder
    func intakeCharacterCounter(_ text: String, limit: Int, styledAsFormRow: Bool = false) -> some View {
        let length = IntakeTextLimits.measuredLength(text)
        if CharacterCounterRow.isVisible(length: length, limit: limit) {
            if styledAsFormRow {
                CharacterCounterRow(length: length, limit: limit)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
            } else {
                CharacterCounterRow(length: length, limit: limit)
            }
        }
    }
}
