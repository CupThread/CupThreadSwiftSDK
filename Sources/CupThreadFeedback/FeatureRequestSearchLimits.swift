import Foundation

/// Client-side bounds for `GET /api/v1/feature-requests` query parameters,
/// mirroring the live OpenAPI contract the same way ``IntakeTextLimits``
/// mirrors the intake caps (#610).
///
/// The endpoint's `q` parameter is documented with `maxLength: 120`, and the
/// search path is rate-limited per client IP (the budget
/// ``SearchRequestThrottle`` spaces requests below) — so an over-long term is
/// a request the server can only reject, yet one that still spends an
/// admission slot before failing. The SDK therefore truncates the term it
/// actually sends to the documented bound, the same way `fetchFeatureRequests`
/// clamps its `limit`/`offset` values instead of letting the gateway reject
/// them.
public enum FeatureRequestSearchLimits: Sendable {
    /// `q` cap in Unicode code points (the live contract's
    /// `maxLength: 120`), measured on the trimmed term that is actually
    /// sent — the #578 counting convention, the same unit the server's
    /// `maxLength` validation counts. Counting Swift `Character`s (grapheme
    /// clusters) instead could let multi-scalar input — flag sequences,
    /// ZWJ emoji, decomposed accents — slip past the bound the wire string
    /// exceeds.
    public static let maxQueryLength = 120

    /// The search term actually sent on the wire (#610): `query` trimmed of
    /// surrounding whitespace, truncated to ``maxQueryLength`` Unicode code
    /// points without splitting a grapheme cluster, then re-trimmed (a cut
    /// can land on interior whitespace, and a trailing space would be sent
    /// verbatim), and `nil` when nothing remains — matching the blank-drop
    /// semantics `fetchFeatureRequests` has always applied.
    ///
    /// Truncating on grapheme-cluster boundaries keeps the clamped term a
    /// prefix made of whole user-perceived characters; dropping the final
    /// partial cluster only shortens it, and a search over the prefix still
    /// returns the matches the unclamped term could not have survived to
    /// return anyway.
    static func sanitizedQuery(_ query: String?) -> String? {
        guard let trimmed = query?.nilIfEmpty else { return nil }
        guard trimmed.unicodeScalars.count > maxQueryLength else { return trimmed }
        return IntakeTextLimits.prefixFitting(trimmed, codePointCap: maxQueryLength).nilIfEmpty
    }
}
