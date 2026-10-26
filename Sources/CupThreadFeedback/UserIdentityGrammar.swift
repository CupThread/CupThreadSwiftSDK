import Foundation

/// The identity grammar a caller-supplied end-user token must match before
/// it may ride on the paths whose live contract types the identity as
/// `format: uuid` (issue #617): `POST /api/v1/feature-requests` (body
/// `requesterToken` and the `X-User-Token` header), `POST`/`DELETE
/// /api/v1/feature-requests/{id}/vote`, and `POST /api/v1/uploads/sessions`
/// (`X-User-Token`). The server can only answer any other value with
/// `400 Validation failed`, so the value is rejected locally — before a
/// single-use Turnstile challenge is consumed or any request is built — the
/// same fail-fast reasoning as the #493 blank/newline gate it layers after.
///
/// Deliberately narrower than `UUID(uuidString:)`: that initializer also
/// accepts braced (`{…}`) and `urn:uuid:`-prefixed spellings a JSON Schema
/// `format: uuid` validator would reject, and this grammar must accept
/// exactly what the wire accepts. `POST /api/v1/feedback`'s `X-User-Token`
/// is a plain string in the live contract, so feedback submissions stay on
/// the #493 gate alone.
enum UserIdentityGrammar {
    /// The positions of the four hyphens in the canonical
    /// `8-4-4-4-12` spelling.
    private static let dashPositions: Set<Int> = [8, 13, 18, 23]

    /// Whether `value` is a canonical hyphenated UUID (8-4-4-4-12 hex
    /// digits, either letter case). Expects an already-trimmed value —
    /// callers pass the output of `validatedUserToken`.
    static func isValid(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count == 36 else { return false }
        for (index, scalar) in scalars.enumerated() {
            if dashPositions.contains(index) {
                guard scalar == "-" else { return false }
            } else {
                guard isHexDigit(scalar) else { return false }
            }
        }
        return true
    }

    private static func isHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        (scalar >= "0" && scalar <= "9")
            || (scalar >= "a" && scalar <= "f")
            || (scalar >= "A" && scalar <= "F")
    }
}
