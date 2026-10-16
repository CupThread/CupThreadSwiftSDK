import Foundation

/// The path-segment grammar a caller-supplied feature-request id must match
/// before it may be interpolated into an API URL path (API-24): one opaque
/// ASCII segment of letters, digits, underscores, or hyphens, 1–128
/// characters — server-issued UUIDs and the `fr-…` style ids both fit.
/// Deep-link, push, and share-link ids come from outside the app, so
/// anything else (path separators, `.` segments, `?`/`#`/`%`, whitespace,
/// non-ASCII, oversized input) is rejected locally before any request is
/// built instead of resolving to a different route on the API origin or
/// corrupting the path.
enum FeatureRequestIDGrammar {
    static let minLength = 1
    static let maxLength = 128

    /// Whether `value` matches the `^[A-Za-z0-9_-]{1,128}$` grammar.
    static func isValid(_ value: String) -> Bool {
        guard (minLength...maxLength).contains(value.count) else { return false }
        return value.allSatisfy { character in
            guard character.isASCII else { return false }
            return character.isLetter || character.isNumber
                || character == "_" || character == "-"
        }
    }
}
