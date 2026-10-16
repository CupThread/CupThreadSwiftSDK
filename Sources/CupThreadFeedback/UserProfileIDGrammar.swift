import Foundation

/// The path-segment grammar a caller-supplied user id must match before it
/// may be interpolated into an API URL path (API-26): one opaque ASCII
/// segment of letters, digits, underscores, or hyphens, 1–128 characters —
/// app-scoped public ids (`u_<32-hex>`) and raw Clerk ids (`user_…`) both
/// fit. Deep-link and bookmark ids come from outside the app, so anything
/// else (path separators, `.` segments, `?`/`#`/`%`, whitespace, non-ASCII,
/// oversized input) is rejected locally before any request is built instead
/// of resolving to a different route on the API origin while carrying the
/// caller's `Authorization` header. Same rule as `FeatureRequestIDGrammar`
/// (API-24), named for the resource it guards.
enum UserProfileIDGrammar {
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
