import CryptoKit
import Foundation

/// Utilities for canonicalizing and HMAC-SHA256 signing end-user attribute reports
/// on `PUT /api/v1/public/apps/{appKey}/user`.
public enum UserAttributesSigner {

    /// Represents a field value in a canonical attribute payload, supporting explicit
    /// `null` vs absent (`unset`).
    public enum Field<T: Sendable>: Sendable, ExpressibleByNilLiteral {
        /// The field is omitted / absent from the payload.
        case unset
        /// The field is explicitly present with a `null` value in JSON.
        case null
        /// The field is present with the given value.
        case value(T)

        /// Creates an absent (`.unset`) field from a `nil` literal.
        public init(nilLiteral: ()) {
            self = .unset
        }
    }

    /// Prefix tag for the canonical string format.
    public static let prefix = "cpt-user-attrs-v1"

    /// Arguments for assembling the canonical string of a user-attribute update request.
    public struct Arguments: Sendable {
        /// The app key identifying the app in CupThread.
        public let appKey: String
        /// The resolved end-user token.
        public let userToken: String
        /// Paying user status.
        public let isPaying: Field<Bool>
        /// Plan name.
        public let plan: Field<String>
        /// Monthly recurring revenue.
        public let mrr: Field<Double>
        /// Currency code as sent in the request.
        public let currency: Field<String>
        /// Integer Unix epoch seconds.
        public let timestamp: Int64

        /// Creates canonical string arguments with explicit field states.
        public init(
            appKey: String,
            userToken: String,
            isPaying: Field<Bool> = .unset,
            plan: Field<String> = .unset,
            mrr: Field<Double> = .unset,
            currency: Field<String> = .unset,
            timestamp: Int64
        ) {
            self.appKey = appKey
            self.userToken = userToken
            self.isPaying = isPaying
            self.plan = plan
            self.mrr = mrr
            self.currency = currency
            self.timestamp = timestamp
        }

        /// Creates canonical string arguments from optional values where nil maps to `.unset`.
        public init(
            appKey: String,
            userToken: String,
            isPaying: Bool? = nil,
            plan: String? = nil,
            mrr: Double? = nil,
            currency: String? = nil,
            timestamp: Int64
        ) {
            self.init(
                appKey: appKey,
                userToken: userToken,
                isPaying: isPaying.map { .value($0) } ?? .unset,
                plan: plan.map { .value($0) } ?? .unset,
                mrr: mrr.map { .value($0) } ?? .unset,
                currency: currency.map { .value($0) } ?? .unset,
                timestamp: timestamp
            )
        }
    }

    /// Renders a numeric value with ECMA-262 `Number.prototype.toFixed(2)` semantics
    /// evaluated on the exact binary double, then strips trailing zeros and a trailing
    /// decimal point — byte-identical to the server's JavaScript canonicalization
    /// (`v.toFixed(2)` + trailing-zero strip, DATA-03).
    ///
    /// The rounding is performed on the *exact* binary value the server receives, not on
    /// the shortest round-trip decimal string: `9.995` is stored as
    /// `9.99499999999999957…` and therefore canonicalizes to `"9.99"`, while `1200.005`
    /// is stored as `1200.00500000000010…` and carries to `"1200.01"`. Exact half-way
    /// values (e.g. `1.125`, which is exactly representable) round away from zero on
    /// both signs, matching the observable `toFixed` behavior of the JS runtimes the
    /// server verifies with (`1.125 → "1.13"`, `-1.125 → "-1.13"`).
    ///
    /// Behavior at the domain edges:
    /// - `-0.0` canonicalizes to `"0"`, like `(-0).toFixed(2)` (`"0.00"`).
    /// - A negative value that rounds below one cent keeps its sign (`-0.004 → "-0"`),
    ///   matching Node's `"-0.00"` after the strip.
    /// - `|value| ≥ 1e21` mirrors ECMA's switch to `ToString` and returns the shortest
    ///   round-trip decimal/exponential string. MRR cannot reach this boundary; the
    ///   check also keeps the fixed-point integer path overflow-free.
    /// - Non-finite values (`NaN`, `±infinity`) canonicalize to `"0"`: JSON cannot
    ///   carry them, and the wire encoder coerces them to `0` so the signed
    ///   canonical string and the transmitted payload always agree (SEC-3).
    ///
    /// - Parameter value: The numeric amount (e.g. MRR).
    /// - Returns: The formatted canonical representation (e.g. `1200`, `99.5`, `12.34`, `0`).
    public static func canonicalNumber(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == 0 { return "0" }
        if value.magnitude >= 1e21 { return "\(value)" }

        // n is the decimal integer such that n / 100 is |value| rounded to two
        // fraction digits; its digits render with two implied fraction places.
        var digits = fixedPointCentiles(for: value)
        if digits.count < 3 {
            digits = String(repeating: "0", count: 3 - digits.count) + digits
        }
        let integerPart = String(digits.dropLast(2))
        var fraction = String(digits.suffix(2))
        while fraction.hasSuffix("0") { fraction.removeLast() }
        var result = fraction.isEmpty ? integerPart : integerPart + "." + fraction
        if value < 0 { result = "-" + result }
        return result
    }

    /// Returns the decimal digits of `n` where `n / 100` is `|value|` rounded to
    /// nearest with exact halves away from zero, computed exactly on the binary
    /// double via IEEE 754 decomposition and 64-bit integer arithmetic.
    private static func fixedPointCentiles(for value: Double) -> String {
        // Decompose |value| = significand × 2^binaryExponent with an integer significand.
        let magnitude = value.magnitude
        let rawExponent = magnitude.exponent
        let significandBits = magnitude.significandBitPattern
        let significand: UInt64
        let binaryExponent: Int
        if rawExponent == -1022 && significandBits != 0 {
            // Subnormal: no implicit leading bit.
            significand = significandBits
            binaryExponent = -1074
        } else {
            significand = significandBits | (1 << 52)
            binaryExponent = rawExponent - 52
        }
        // scaled = |value| × 100 exactly: significand < 2^53 so scaled < 2^60.
        let scaled = significand * 100

        if binaryExponent >= 0 {
            // Integer-valued double: n = scaled × 2^binaryExponent exactly.
            if binaryExponent <= scaled.leadingZeroBitCount {
                return String(scaled << binaryExponent)
            }
            var decimal = Decimal(scaled)
            for _ in 0..<binaryExponent { decimal *= 2 }
            return "\(decimal)"
        }

        // n = scaled / 2^shift rounded to nearest, exact halves away from zero.
        let shift = -binaryExponent
        let quotient: UInt64
        let roundUp: Bool
        if shift <= 59 {
            quotient = scaled >> shift
            let remainder = scaled & ((UInt64(1) << shift) - 1)
            roundUp = remainder >= (UInt64(1) << (shift - 1))
        } else {
            quotient = 0
            roundUp = shift <= 61 && scaled >= (UInt64(1) << (shift - 1))
        }
        return String(quotient + (roundUp ? 1 : 0))
    }

    /// Replaces CR/LF sequences in a host-supplied string with single spaces so
    /// it can never inject additional lines into the newline-delimited
    /// canonical string (SEC-3): a plan of `"pro\n1200\nUSD\n1773600000"` would
    /// otherwise shift every following field and desynchronize — or forge —
    /// the HMAC. ``UserAttributesPayload``'s encoder applies the same
    /// replacement to the values it sends, so the server's canonicalization of
    /// the received payload always reconstructs the signed string.
    ///
    /// - Parameter string: The raw field value (e.g. a plan name).
    /// - Returns: A single-line rendering of the value.
    static func sanitizedLine(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Assembles the canonical string for a user-attribute update request from arguments.
    ///
    /// Canonical format (newline-joined, no trailing newline):
    /// ```
    /// cpt-user-attrs-v1
    /// <appKey>
    /// <userToken>
    /// <isPaying: true|false|unset>
    /// <plan: value|null|unset>
    /// <mrr: canonicalNumber|null|unset>
    /// <currency: valueAsSent|unset>
    /// <timestamp: epochSeconds>
    /// ```
    ///
    /// `appKey`, `userToken`, and string field values are newline-sanitized
    /// (SEC-3): CR/LF sequences in host-supplied strings become single spaces,
    /// so the canonical form always contains exactly the eight lines above.
    ///
    /// - Parameter arguments: The arguments specifying each field value.
    /// - Returns: The exact canonical string to be HMAC-signed.
    public static func canonicalString(for arguments: Arguments) -> String {
        let lines = [
            prefix,
            sanitizedLine(arguments.appKey),
            sanitizedLine(arguments.userToken),
            arguments.isPaying.canonicalRepresentation,
            arguments.plan.canonicalRepresentation,
            arguments.mrr.canonicalRepresentation,
            arguments.currency.canonicalRepresentation,
            "\(arguments.timestamp)"
        ]
        return lines.joined(separator: "\n")
    }

    /// Computes the HMAC-SHA256 signature for the given canonical string and signing secret.
    ///
    /// - Parameters:
    ///   - canonicalString: The newline-delimited canonical string.
    ///   - secret: The SDK signing secret key.
    /// - Returns: A 64-character lowercase hexadecimal string.
    public static func signature(for canonicalString: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: Data(canonicalString.utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }
}

extension UserAttributesSigner.Field: Equatable where T: Equatable {}

extension UserAttributesSigner.Field where T == Bool {
    var canonicalRepresentation: String {
        switch self {
        case .unset:
            return "unset"
        case .null:
            return "null"
        case .value(let bool):
            return bool ? "true" : "false"
        }
    }
}

extension UserAttributesSigner.Field where T == String {
    var canonicalRepresentation: String {
        switch self {
        case .unset:
            return "unset"
        case .null:
            return "null"
        case .value(let string):
            // A raw value must never carry the record's "\n" delimiter onto a
            // line of its own (SEC-3).
            return UserAttributesSigner.sanitizedLine(string)
        }
    }
}

extension UserAttributesSigner.Field where T == Double {
    var canonicalRepresentation: String {
        switch self {
        case .unset:
            return "unset"
        case .null:
            return "null"
        case .value(let double):
            return UserAttributesSigner.canonicalNumber(double)
        }
    }
}
