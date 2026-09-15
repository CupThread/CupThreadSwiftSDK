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

    /// Renders a numeric value with round-half-even IEEE 754 double formatting
    /// (`toFixed(2)` semantics), then strips trailing zeros and a trailing decimal point.
    ///
    /// - Parameter value: The numeric amount (e.g. MRR).
    /// - Returns: The formatted canonical representation (e.g. `1200`, `99.5`, `12.34`, `0`).
    public static func canonicalNumber(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.roundingMode = .halfEven
        formatter.usesGroupingSeparator = false
        guard let formatted = formatter.string(from: NSNumber(value: value)) else {
            return "\(value)"
        }
        var string = formatted
        while string.contains(".") && (string.hasSuffix("0") || string.hasSuffix(".")) {
            string.removeLast()
        }
        return string
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
    /// - Parameter arguments: The arguments specifying each field value.
    /// - Returns: The exact canonical string to be HMAC-signed.
    public static func canonicalString(for arguments: Arguments) -> String {
        let lines = [
            prefix,
            arguments.appKey,
            arguments.userToken,
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
            return string
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
