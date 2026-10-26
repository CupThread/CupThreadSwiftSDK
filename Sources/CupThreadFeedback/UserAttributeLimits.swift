import Foundation

/// Client-side value bounds for the payment-attribute report fields
/// (issue #607), mirroring the live `EndUserAttributesInput` schema the
/// same way ``IntakeTextLimits`` mirrors the intake caps: a `plan`, `mrr`,
/// or `currency` outside these bounds is a deterministic HTTP `400
/// Validation failed` — and because the whole report is validated as one
/// object server-side, every sibling write in the same `PUT` is silently
/// dropped with it. ``FeedbackClient/updateUserAttributes`` enforces the
/// bounds before any signing material is consulted or any bytes reach the
/// network.
public enum UserAttributeLimits: Sendable {
    /// Plan-name floor, in Unicode code points
    /// (`EndUserAttributesInput.plan` `minLength`). The empty string is
    /// rejected: model "no plan" by omitting the attribute (`.unset`) or
    /// clearing it (`.null`) on the
    /// ``UserAttributesSigner/Field`` overload — never with `.value("")`.
    public static let minPlanLength = 1
    /// Plan-name cap, in Unicode code points
    /// (`EndUserAttributesInput.plan` `maxLength`), counted on the
    /// CR/LF-sanitized value that is actually signed and sent (SEC-3).
    public static let maxPlanLength = 64
    /// Monthly-recurring-revenue floor (`EndUserAttributesInput.mrr`
    /// `minimum`). A non-finite `Double` is coerced to `0` before the
    /// bounds check and on the wire (SEC-3), so it passes at this floor.
    public static let minMRR: Double = 0
    /// Monthly-recurring-revenue cap (`EndUserAttributesInput.mrr`
    /// `maximum`), inclusive.
    public static let maxMRR: Double = 1_000_000
    /// Currency-code length: exactly three ASCII letters, matched as
    /// sent (the server uppercases after validation, and the signature
    /// covers the raw value).
    public static let currencyLetterCount = 3

    /// Rejects a report whose `plan`, `mrr`, or `currency` **value** is
    /// outside the live `EndUserAttributesInput` bounds (issue #607),
    /// the value-level counterpart of the `.null` clearability gate
    /// (#573). `.unset` and `.null` keep their current semantics and are
    /// never bounds-checked. Enforced before signing: a report that
    /// cannot succeed must not consume the backend-delegated signer
    /// provider (a network round trip for most SEC-19 hosts) or HMAC
    /// with the embedded secret — and the whole PUT would silently drop
    /// every sibling write with it.
    static func validateValueBounds(
        plan: UserAttributesSigner.Field<String>,
        mrr: UserAttributesSigner.Field<Double>,
        currency: UserAttributesSigner.Field<String>
    ) throws {
        try validatePlanValue(plan)
        try validateMRRValue(mrr)
        try validateCurrencyValue(currency)
    }

    /// The sanitized line is what the canonical string signs and the
    /// encoder sends, so it is the value the plan bounds apply to.
    private static func validatePlanValue(_ plan: UserAttributesSigner.Field<String>) throws {
        guard case .value(let rawPlan) = plan else { return }
        let length = UserAttributesSigner.sanitizedLine(rawPlan).unicodeScalars.count
        guard length >= minPlanLength, length <= maxPlanLength else {
            throw FeedbackClientError.invalidAttributeValue(
                attribute: "plan",
                message: "plan must be \(minPlanLength)...\(maxPlanLength) code points (got \(length))",
                requestId: nil
            )
        }
    }

    /// Same coercion the wire encoder applies (SEC-3): NaN/infinity are
    /// sent as `0`, so the bounds check the coerced value.
    private static func validateMRRValue(_ mrr: UserAttributesSigner.Field<Double>) throws {
        guard case .value(let rawMRR) = mrr else { return }
        let mrrValue = rawMRR.isFinite ? rawMRR : 0
        guard mrrValue >= minMRR, mrrValue <= maxMRR else {
            throw FeedbackClientError.invalidAttributeValue(
                attribute: "mrr",
                message: "mrr must be between \(Int(minMRR)) and \(Int(maxMRR)) inclusive (got \(rawMRR))",
                requestId: nil
            )
        }
    }

    private static func validateCurrencyValue(_ currency: UserAttributesSigner.Field<String>) throws {
        guard case .value(let rawCurrency) = currency else { return }
        let isThreeLetters = rawCurrency.count == currencyLetterCount
            && rawCurrency.allSatisfy { $0.isASCII && $0.isLetter }
        guard isThreeLetters else {
            throw FeedbackClientError.invalidAttributeValue(
                attribute: "currency",
                message: "currency must be exactly \(currencyLetterCount) ASCII letters (got \"\(rawCurrency)\")",
                requestId: nil
            )
        }
    }
}
