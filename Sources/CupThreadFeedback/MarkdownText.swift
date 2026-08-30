import SwiftUI

/// Renders inline Markdown (bold, italic, code, links) via `AttributedString`,
/// falling back to plain text when parsing fails. Line breaks are preserved so
/// list-style bodies still read as separate lines.
struct MarkdownText: View {
    let content: String

    var body: some View {
        Text(Self.attributed(content))
    }

    static func attributed(_ content: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: content, options: options))
            ?? AttributedString(content)
    }
}
