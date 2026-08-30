import SwiftUI

/// Renders text with every case-insensitive occurrence of `query` highlighted
/// (accent color + bold). Falls back to plain text when the query is empty or
/// matches nothing, so non-search rendering is unchanged.
struct HighlightedText: View {
    let text: String
    let query: String

    var body: some View {
        Text(highlighted)
    }

    private var highlighted: AttributedString {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let regex = try? NSRegularExpression(
                  pattern: NSRegularExpression.escapedPattern(for: trimmed),
                  options: [.caseInsensitive]
              ) else {
            return AttributedString(text)
        }

        let matches = regex.matches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length)
        )
        guard !matches.isEmpty else {
            return AttributedString(text)
        }

        // Rebuild from segments (matched / unmatched) so indices stay in sync.
        var result = AttributedString()
        var cursor = text.startIndex
        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            if cursor < matchRange.lowerBound {
                result += AttributedString(String(text[cursor..<matchRange.lowerBound]))
            }
            var hit = AttributedString(String(text[matchRange]))
            hit.foregroundColor = Color.accentColor
            hit.inlinePresentationIntent = .stronglyEmphasized
            result += hit
            cursor = matchRange.upperBound
        }
        if cursor < text.endIndex {
            result += AttributedString(String(text[cursor...]))
        }
        return result
    }
}
