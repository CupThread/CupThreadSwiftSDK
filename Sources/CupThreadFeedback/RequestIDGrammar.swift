import Foundation

/// The correlation-id grammar shared by both directions of the
/// `X-Request-Id` header (OPS-01): requests send ids matching
/// `^[A-Za-z0-9._-]{8,64}$`, the server honors exactly those ids and
/// replaces anything else, and echoed response headers are only propagated
/// when they conform (SEC-12). Any other echo value — HTML from a captive
/// portal, a phishing nudge injected by a TLS proxy, oversized junk from a
/// gateway — is not a correlation id and must never reach user-facing
/// error copy.
enum RequestIDGrammar {
    static let minLength = 8
    static let maxLength = 64

    /// Whether `value` matches the `^[A-Za-z0-9._-]{8,64}$` grammar.
    static func isValid(_ value: String) -> Bool {
        guard (minLength...maxLength).contains(value.count) else { return false }
        return value.allSatisfy { character in
            guard character.isASCII else { return false }
            return character.isLetter || character.isNumber
                || character == "." || character == "_" || character == "-"
        }
    }
}
