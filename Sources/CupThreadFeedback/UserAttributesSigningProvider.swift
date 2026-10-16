import Foundation

// MARK: - Backend-Delegated Payment-Attribute Signing (SEC-19)

/// The signing material a backend-delegated signer receives for a
/// payment-attribute report on `PUT /api/v1/public/apps/{appKey}/user`.
///
/// The SDK builds the canonical string itself — with its server-clock-corrected
/// timestamp (API-19) — and hands it to the ``FeedbackClient/init(configuration:session:turnstileTokenProvider:authenticationProvider:userAttributesSigner:)``
/// provider. HMAC-SHA256 the exact ``canonicalString`` bytes with the SDK
/// signing secret held server-side (StoreKit server notifications, RevenueCat
/// webhooks, and similar entitlement sources live there — never in the app
/// binary) and return the result as a ``UserAttributesSignature``.
///
/// The last line of ``canonicalString`` is the signature timestamp; the HMAC
/// must cover it as-is, and the returned ``UserAttributesSignature/timestamp``
/// must be that same value — the SDK sends it verbatim in the payload's
/// `timestamp` field, and the server verifies the signature against a
/// canonical string it rebuilds from the received payload.
public struct UserAttributesSigningRequest: Sendable {
    /// The exact canonical string to HMAC — byte-identical to
    /// ``UserAttributesSigner/canonicalString(for:)`` for ``arguments``.
    public let canonicalString: String
    /// The structured arguments that produced ``canonicalString``.
    public let arguments: UserAttributesSigner.Arguments

    /// Creates a signing request from its canonical string and arguments.
    /// - Parameters:
    ///   - canonicalString: The exact canonical string to be HMAC-signed.
    ///   - arguments: The arguments that produced `canonicalString`.
    public init(canonicalString: String, arguments: UserAttributesSigner.Arguments) {
        self.canonicalString = canonicalString
        self.arguments = arguments
    }
}

/// A signature over a ``UserAttributesSigningRequest/canonicalString``,
/// produced wherever the SDK signing secret lives — normally the host's
/// backend, so the secret never ships inside the app binary (SEC-19).
public struct UserAttributesSignature: Sendable {
    /// The HMAC-SHA256 of the canonical string: exactly 64 hexadecimal
    /// characters. Values outside that grammar are rejected locally with
    /// ``FeedbackClientError/invalidSignature(message:requestId:)`` before
    /// any request is built.
    public let signature: String
    /// The epoch seconds embedded in the signed canonical string (its last
    /// line). Sent verbatim as the payload's `timestamp` field.
    public let timestamp: Int64

    /// Creates a signature for a canonical string.
    /// - Parameters:
    ///   - signature: The 64-hex-character HMAC-SHA256 of the canonical string.
    ///   - timestamp: The epoch seconds embedded in the signed canonical string.
    public init(signature: String, timestamp: Int64) {
        self.signature = signature
        self.timestamp = timestamp
    }
}

/// The grammar of an HMAC-SHA256 signature (`^[0-9a-fA-F]{64}$`), validated
/// before a provider-returned value reaches the wire so a misbehaving backend
/// signer fails fast locally instead of spending a request the server must
/// reject.
enum UserAttributesSignatureGrammar {
    static let length = 64

    /// Whether `signature` matches the `^[0-9a-fA-F]{64}$` grammar.
    static func isValid(_ signature: String) -> Bool {
        guard signature.count == length else { return false }
        return signature.allSatisfy { character in
            guard character.isASCII else { return false }
            return ("a"..."f").contains(character) || ("A"..."F").contains(character) || character.isNumber
        }
    }
}
