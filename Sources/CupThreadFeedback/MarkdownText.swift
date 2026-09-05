import SwiftUI

/// Renders inline Markdown (bold, italic, code, links) via `AttributedString`,
/// falling back to plain text when parsing fails. Line breaks are preserved so
/// list-style bodies still read as separate lines.
/// Non-web link schemes (e.g. `tel:`, `javascript:`, custom app schemes) are
/// neutralized so untrusted content cannot invoke privileged system handlers.
struct MarkdownText: View {
    let content: String

    var body: some View {
        Text(Self.attributed(content))
            .safeWebOpenURL()
    }

    static func attributed(_ content: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        let parsed = (try? AttributedString(markdown: content, options: options))
            ?? AttributedString(content)
        return sanitizeMarkdownAttributedString(parsed)
    }
}
