import Foundation

/// The grammars a caller-supplied user id must satisfy before it may be
/// interpolated into an API URL path and before it is dispatched to the
/// public profile endpoint (API-26, #512).
///
/// Two separate rules live here:
///
/// - ``isValid(_:)`` is the path-segment grammar: one opaque ASCII segment
///   of letters, digits, underscores, or hyphens, 1–128 characters. Deep-link
///   and bookmark ids come from outside the app, so anything else (path
///   separators, `.` segments, `?`/`#`/`%`, whitespace, non-ASCII, oversized
///   input) is rejected locally instead of resolving to a different route on
///   the API origin while carrying the caller's `Authorization` header. Same
///   rule as `FeatureRequestIDGrammar` (API-24).
/// - ``isPseudonym(_:)`` is the resolution grammar: the app-scoped public
///   id shape (`u_` plus 32 lowercase hex characters) that
///   `GET /api/v1/users/{userId}/profile` resolves. Since PRIV-06 (#1314,
///   SaaS#1322) that unauthenticated endpoint resolves app-scoped pseudonyms
///   only — every other identifier, raw Clerk ids (`user_…`) included, comes
///   back as the anonymous placeholder rather than a real profile.
enum UserProfileIDGrammar {
    static let minLength = 1
    static let maxLength = 128

    /// Number of lowercase hex characters after the `u_` prefix in an
    /// app-scoped pseudonym. Mirrors the server's `PUBLIC_USER_ID_RE`
    /// (`^u_[0-9a-f]{32}$`).
    static let pseudonymHexLength = 32

    /// Whether `value` matches the `^[A-Za-z0-9_-]{1,128}$` path grammar.
    static func isValid(_ value: String) -> Bool {
        guard (minLength...maxLength).contains(value.count) else { return false }
        return value.allSatisfy { character in
            guard character.isASCII else { return false }
            return character.isLetter || character.isNumber
                || character == "_" || character == "-"
        }
    }

    /// Whether `value` is an app-scoped pseudonym (`u_` + 32 lowercase hex
    /// characters) — the only identifier shape the public profile endpoint
    /// resolves to a real profile.
    static func isPseudonym(_ value: String) -> Bool {
        guard value.count == 2 + pseudonymHexLength,
              value.hasPrefix("u_") else { return false }
        return value.dropFirst(2).allSatisfy { character in
            character.isASCII && (character.isNumber || ("a"..."f").contains(character))
        }
    }
}
