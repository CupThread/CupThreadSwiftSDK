import Foundation

/// Lightweight, dependency-free email plausibility check shared by the SDK
/// surfaces that collect an email address (#283).
///
/// This is a shape check, not validation: it catches obvious typos the user
/// would want to know about (`user@@example.com`, `user@host`,
/// `user@example..com`) without pretending to implement RFC 5322 — edge-case
/// but real addresses stay submittable, and the server remains authoritative.
enum EmailShape {
    /// Whether the string has the shape of a usable email address.
    ///
    /// Leading/trailing whitespace is tolerated and trimmed first; whitespace
    /// *inside* the address fails. The rules beyond that are: exactly one
    /// `@`, a non-empty local part, and a domain made of at least two
    /// non-empty dot-separated labels (so empty labels, a trailing dot, and
    /// a bare host all fail — the gaps #281 documented in the previous
    /// subscribe-sheet heuristic).
    static func isPlausible(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: \.isWhitespace),
              trimmed.filter({ $0 == "@" }).count == 1 else {
            return false
        }

        let at = trimmed.firstIndex(of: "@")!
        let localPart = trimmed[..<at]
        let domain = trimmed[trimmed.index(after: at)...]
        guard !localPart.isEmpty, !domain.isEmpty else { return false }

        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { !$0.isEmpty }
    }
}
