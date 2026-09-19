import Foundation
import Testing
@testable import CupThreadFeedback

/// Fails when user-facing SwiftUI copy is written as a hard-coded string
/// literal instead of going through `CupThreadStrings.tr(_:)` (issue #9).
///
/// The scan is intentionally heuristic: it flags the first argument of
/// `Text`/`Label`/`Button`/`Toggle`/`TextField`/`ProgressView`, accessibility
/// labels/values/hints, navigation titles, and `NSLocalizedDescriptionKey`
/// error messages when they are passed as string literals. Dynamic user
/// content (interpolated handles) and language-neutral glyphs stay
/// allow-listed below.
@Suite("Localization guard")
struct LocalizationGuardTests {
    /// Literals that are deliberately not localized.
    private static let allowList: Set<String> = [
        "···"  // ellipsis glyph, language-neutral
    ]

    private static let patterns: [(name: String, regex: NSRegularExpression)] = {
        let specs = [
            ("view text", #"\b(?:Text|Label|Button|Toggle|TextField|ProgressView)\("([^"]*)""#),
            ("accessibility", #"\.accessibility(?:Label|Value|Hint)\("([^"]*)""#),
            ("navigation title", #"\.navigationTitle\("([^"]*)""#),
            ("error message", #"NSLocalizedDescriptionKey:\s*"([^"]*)""#)
        ]
        return specs.compactMap { name, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (name, regex)
        }
    }()

    private func sourceDirectory() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            directory.deleteLastPathComponent()
            let candidate = directory
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CupThreadFeedback", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        try #require(
            false,
            "Could not locate Sources/CupThreadFeedback by walking up from \(#filePath)"
        )
        return URL(fileURLWithPath: #filePath) // unreachable; #require throws first
    }

    @Test func userFacingLiteralsAreLocalized() throws {
        let directory = try sourceDirectory()
        let files = try #require(
            FileManager.default
                .enumerator(at: directory, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" },
            "Failed to enumerate Swift sources under \(directory)"
        )
        try #require(!files.isEmpty, "No Swift sources found under \(directory)")

        var violations: [String] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let source = try String(contentsOf: file, encoding: .utf8)
            let lines = source.components(separatedBy: .newlines)
            for (offset, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                    continue
                }
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                for (name, regex) in Self.patterns {
                    for match in regex.matches(in: line, range: range) {
                        guard let matchRange = Range(match.range(at: 1), in: line) else { continue }
                        let literal = String(line[matchRange])
                        if Self.allowList.contains(literal) { continue }
                        if literal.hasPrefix("@\\(") { continue }  // dynamic user handles
                        violations.append("\(file.lastPathComponent):\(offset + 1) [\(name)] \(literal)")
                    }
                }
            }
        }

        #expect(
            violations.isEmpty,
            "User-facing copy must go through CupThreadStrings.tr(_:). Unlocalized literals:\n\(violations.joined(separator: "\n"))"
        )
    }
}
