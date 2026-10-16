import Foundation

/// The app-key grammar every outgoing request validates against before
/// dispatch (SEC-22): keys are minted by the CupThread developer console and
/// match `^[A-Za-z0-9_.-]{1,64}$` — issued keys start with `app_`. The
/// configuration trims surrounding whitespace at init; a value still outside
/// the grammar (blank, path separators, traversal sequences, control
/// characters, Unicode look-alikes, oversize) can never form a legal
/// endpoint path, query item, Turnstile `cdata`, or HMAC canonical line, so
/// dispatch rejects it with
/// ``FeedbackClientError/invalidConfiguration(message:)`` before any network
/// round trip instead of transmitting a mangled route.
enum AppKeyGrammar {
    /// The console's maximum app-key length.
    static let maxLength = 64

    /// `value` with surrounding whitespace removed — the normalization
    /// ``FeedbackClientConfiguration`` applies at init and every scoped
    /// storage key mirrors, so a padded value can never mint an identity
    /// distinct from its trimmed form (SEC-22).
    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `value` matches the `^[A-Za-z0-9_.-]{1,64}$` grammar.
    /// Expects an already-``normalized(_:)`` value; path separators and
    /// traversal sequences are rejected outright, so a hostile or
    /// misconfigured key cannot escape the `/api/v1/` route prefix through
    /// `URL.appending(path:)`.
    static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty, !value.contains(".."), value.count <= maxLength else {
            return false
        }
        return value.allSatisfy { character in
            guard character.isASCII else { return false }
            return character.isLetter || character.isNumber
                || character == "." || character == "_" || character == "-"
        }
    }
}
