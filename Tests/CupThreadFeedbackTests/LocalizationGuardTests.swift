import Foundation
import Testing
@testable import CupThreadFeedback

/// Fails when user-facing SwiftUI copy is written as a hard-coded string
/// literal instead of going through `CupThreadStrings.tr(_:)` (issue #9),
/// or when a `LocalizedError` description property embeds display literals
/// instead of catalog keys (issue #266).
///
/// The scan is intentionally heuristic: it flags the first argument of
/// `Text`/`Label`/`Button`/`Toggle`/`TextField`/`ProgressView`, accessibility
/// labels/values/hints, navigation titles, `NSLocalizedDescriptionKey`
/// error messages, string literals in ternary branches, and any display
/// literal inside `errorDescription`/`failureDescription`/
/// `recoverySuggestion` bodies. Dynamic user content (interpolated handles)
/// and language-neutral glyphs stay allow-listed below.
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
            ("error message", #"NSLocalizedDescriptionKey:\s*"([^"]*)""#),
            ("ternary branch", #"^\s*(?:\?|:)\s*"([^"]+)""#)
        ]
        return specs.compactMap { name, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (name, regex)
        }
    }()

    /// `LocalizedError` description properties whose bodies must resolve
    /// through the string tables: a bare `return "…"` inside one regresses
    /// user-facing copy to hardcoded English (issue #266).
    private static let localizedErrorProperties = [
        "errorDescription", "failureDescription", "recoverySuggestion"
    ]

    /// Table keys are expected literals — stripped before hunting for
    /// display copy (e.g. `CupThreadStrings.tr("cupthread.error.…")`).
    private static let tableLookupRegex: NSRegularExpression = {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:CupThreadStrings\.)?(?:tr|trPlural|key)\(\s*"(?:[^"\\]|\\.)*""#
        ) else {
            preconditionFailure("Invalid table-lookup regex")
        }
        return regex
    }()

    private static let anyLiteralRegex: NSRegularExpression = {
        guard let regex = try? NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#) else {
            preconditionFailure("Invalid string-literal regex")
        }
        return regex
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
            violations.append(contentsOf: Self.violations(fileName: file.lastPathComponent, source: source))
        }

        #expect(
            violations.isEmpty,
            "User-facing copy must go through CupThreadStrings.tr(_:). Unlocalized literals:\n\(violations.joined(separator: "\n"))"
        )
    }

    /// The `LocalizedError` scan catches a `return "English sentence."`
    /// inside an `errorDescription` body (issue #266) while accepting the
    /// catalog-key form — regression-proofing the guard itself.
    @Test func errorDescriptionLiteralsAreFlagged() {
        let violating = """
        struct SyntheticError: LocalizedError {
            var errorDescription: String? {
                return "English sentence."
            }
        }
        """
        #expect(
            !Self.violations(fileName: "Synthetic.swift", source: violating).isEmpty,
            "A return of an English literal inside errorDescription must be flagged"
        )

        let compliant = """
        struct SyntheticError: LocalizedError {
            var errorDescription: String? {
                CupThreadStrings.tr("cupthread.error.synthetic")
            }
        }
        """
        #expect(
            Self.violations(fileName: "Synthetic.swift", source: compliant).isEmpty,
            "A catalog-key errorDescription must not be flagged"
        )
    }

    /// Scans one source file: the line-based view-copy patterns plus the
    /// `LocalizedError` property-body scan. Static and source-driven so the
    /// detection itself can be regression-tested with synthetic input.
    static func violations(fileName: String, source: String) -> [String] {
        var violations: [String] = []
        let lines = source.components(separatedBy: .newlines)
        for (offset, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                continue
            }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            for (name, regex) in patterns {
                for match in regex.matches(in: line, range: range) {
                    guard let matchRange = Range(match.range(at: 1), in: line) else { continue }
                    let literal = String(line[matchRange])
                    if allowList.contains(literal) { continue }
                    if literal.hasPrefix("@\\(") { continue }  // dynamic user handles
                    violations.append("\(fileName):\(offset + 1) [\(name)] \(literal)")
                }
            }
        }
        if source.contains("LocalizedError") {
            violations.append(
                contentsOf: localizedErrorPropertyViolations(fileName: fileName, lines: lines)
            )
        }
        return violations
    }

    /// Flags display literals inside the bodies of `LocalizedError`
    /// description properties. Property scope is tracked by counting braces
    /// from the `var <property> {` declaration line to its closing brace.
    private static func localizedErrorPropertyViolations(fileName: String, lines: [String]) -> [String] {
        var violations: [String] = []
        var propertyDepth = 0
        for (offset, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                continue
            }
            let opens = trimmed.filter { $0 == "{" }.count
            let closes = trimmed.filter { $0 == "}" }.count
            if propertyDepth > 0 {
                propertyDepth += opens - closes
                if propertyDepth > 0 {
                    violations.append(
                        contentsOf: bodyLiteralViolations(in: line, fileName: fileName, lineNumber: offset + 1)
                    )
                } else {
                    propertyDepth = 0
                }
            } else if opens > 0,
                      localizedErrorProperties.contains(where: { trimmed.contains("var \($0)") }) {
                propertyDepth = opens - closes
                if propertyDepth > 0 {
                    // One-line body, e.g. `var errorDescription: String? { return "…" }`.
                    violations.append(
                        contentsOf: bodyLiteralViolations(in: line, fileName: fileName, lineNumber: offset + 1)
                    )
                }
            }
        }
        return violations
    }

    /// Flags any string literal in a property body that is not a table key,
    /// the empty string, an allow-listed glyph, or pure format/punctuation
    /// content (`""` and `"%@"`-style leftovers carry no English words).
    private static func bodyLiteralViolations(in line: String, fileName: String, lineNumber: Int) -> [String] {
        guard line.contains("\"") else { return [] }
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        let stripped = tableLookupRegex.stringByReplacingMatches(
            in: line, range: fullRange, withTemplate: ""
        )
        let strippedRange = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
        var violations: [String] = []
        for match in anyLiteralRegex.matches(in: stripped, range: strippedRange) {
            guard let matchRange = Range(match.range, in: stripped) else { continue }
            let literal = String(stripped[matchRange])
            let content = String(literal.dropFirst().dropLast())
            if content.isEmpty { continue }
            if allowList.contains(content) { continue }
            if !content.contains(where: \.isLetter) { continue }
            violations.append("\(fileName):\(lineNumber) [error description] \(content)")
        }
        return violations
    }
}
