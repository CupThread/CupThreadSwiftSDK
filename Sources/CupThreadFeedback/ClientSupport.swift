import Foundation

// MARK: - Shared response plumbing (September API sync)

/// The error envelope shared by every public endpoint:
/// `{"error": "...", "code": "..."}` (`code` is optional and machine-readable).
struct APIErrorEnvelope: Decodable, Sendable {
    let error: String?
    let code: String?
}

extension HTTPURLResponse {
    /// The `X-Request-Id` correlation header (OPS-01) the server attaches to
    /// every response — the caller's request id when format-valid, otherwise
    /// a server-generated UUID. Quote it in bug reports and support requests.
    var cupthreadRequestID: String? {
        guard let value = value(forHTTPHeaderField: "X-Request-Id"), !value.isEmpty else {
            return nil
        }
        return value
    }
}

extension FeedbackClient {
    /// The `X-Request-Id` to send with a request (OPS-01): the
    /// configuration's stable id when set, otherwise a fresh UUID per request.
    /// The server honors ids matching `^[A-Za-z0-9._-]{8,64}$` and replaces
    /// anything else.
    func nextRequestID() -> String {
        if let requestID = configuration.requestID, !requestID.isEmpty {
            return requestID
        }
        return UUID().uuidString.lowercased()
    }

    /// Sets the correlation headers shared by every request.
    func applyCorrelationHeaders(
        userToken: String?,
        requestID: String,
        to request: inout URLRequest
    ) {
        applyUserToken(userToken, to: &request)
        request.setValue(requestID, forHTTPHeaderField: "X-Request-Id")
    }

    /// Validates a response status, mapping the API's documented failure
    /// modes to typed errors and attaching the response's `X-Request-Id`.
    /// - Parameters:
    ///   - httpResponse: The received response.
    ///   - data: The raw response body, for the error envelope and message.
    ///   - accepted: Status codes that mean success for this endpoint.
    func validateResponse(
        _ httpResponse: HTTPURLResponse,
        data: Data,
        accepted: Set<Int>
    ) throws {
        let statusCode = httpResponse.statusCode
        guard !accepted.contains(statusCode) else { return }
        let requestId = httpResponse.cupthreadRequestID
        let envelope = try? decoder.decode(APIErrorEnvelope.self, from: data)
        let message = envelope?.error ?? String(data: data, encoding: .utf8) ?? "Unknown error"

        switch statusCode {
        case 422 where envelope?.code == "scan_rejected":
            // An uploadId referenced by the submission failed the
            // server-side content inspection (PRIV-02 media policy).
            throw FeedbackClientError.scanRejected(message: envelope?.error ?? "")
        case 429:
            // Per-client-IP rate limiting (votes, uploads, PUT /user, search).
            throw FeedbackClientError.rateLimited(message: envelope?.error)
        case 415:
            // Upload media policy: SVG rejected, declared MIME must match
            // magic bytes; only PNG, JPEG, WebP, and GIF are accepted.
            throw FeedbackClientError.unsupportedMediaType(message: envelope?.error)
        case 413:
            throw FeedbackClientError.payloadTooLarge(message: envelope?.error)
        case 402 where envelope?.code == "tier_limit_submissions":
            // The app's workspace hit its monthly submission quota — feature
            // requests and feedback enforce the same contract.
            throw FeedbackClientError.submissionQuotaExceeded(message: envelope?.error)
        case 402 where envelope?.code == "subscription_inactive":
            // The app's workspace subscription is inactive or canceled.
            throw FeedbackClientError.subscriptionInactive(message: envelope?.error)
        case 400 where envelope?.code == "uploader_identity_required":
            throw FeedbackClientError.uploaderIdentityRequired(message: envelope?.error)
        case 400 where envelope?.code == "uploader_mismatch":
            throw FeedbackClientError.uploaderMismatch(message: envelope?.error)
        default:
            throw FeedbackClientError.unexpectedStatus(code: statusCode, message: message, requestId: requestId)
        }
    }
}

// MARK: - Feedback metadata redaction (PRIV-01 contract, client side)

/// Mirrors the server-side feedback metadata redaction contract (PRIV-01) locally so
/// oversized or credential-looking metadata never leaves the device: keys
/// must match `[A-Za-z0-9_.:-]{1,64}` (max 24), credential-looking keys are
/// normalized (camelCase split to kebab-case, lowercased) and matched with whole-word
/// boundaries against the authoritative server sensitive pattern, values are truncated
/// to 512 characters, and the serialized total is capped at 8 KB. SDK-reserved keys
/// (`sdk`, `platform`, `submittedAt`) are prioritized to survive host key-count eviction.
/// Payloads are shrunk, never rejected.
enum FeedbackMetadataSanitizer {
    static let maxKeys = 24
    static let maxValueLength = 512
    static let maxTotalBytes = 8_192
    static let redactedValue = "[redacted]"

    /// Reserved metadata keys added by the SDK that must survive key-count eviction.
    static let reservedKeyNames: Set<String> = ["sdk", "platform", "submittedAt"]

    /// Sensitive keyword patterns mirroring the server's PRIV-01 word list.
    static let credentialKeyWords: [String] = [
        "pass(word|wd)?", "secret", "token", "api[-_ ]?key", "access[-_ ]?key",
        "client[-_ ]?secret", "credential", "auth(orization)?", "cookie",
        "session", "bearer", "private[-_ ]?key", "sign(ature)?", "jwt",
        "otp", "ssn", "credit[-_ ]?card", "card[-_ ]?number"
    ]

    private static let camelCaseRegex: NSRegularExpression = {
        (try? NSRegularExpression(pattern: "([a-z0-9])([A-Z])")) ?? NSRegularExpression()
    }()

    private static let sensitiveKeyRegex: NSRegularExpression = {
        let sensitiveWords = [
            "pass(word|wd)?", "secret", "token", "api[-_ ]?key",
            "access[-_ ]?key", "client[-_ ]?secret", "credential",
            "auth(orization)?", "cookie", "session", "bearer",
            "private[-_ ]?key", "sign(ature)?", "jwt", "otp",
            "ssn", "credit[-_ ]?card", "card[-_ ]?number"
        ].joined(separator: "|")
        let pattern = "(^|[^a-z0-9])(\(sensitiveWords))([^a-z0-9]|$)"
        return (try? NSRegularExpression(pattern: pattern)) ?? NSRegularExpression()
    }()

    /// Applies the redaction contract to flat string metadata.
    ///
    /// Evaluation is deterministic: keys are considered in sorted order, so
    /// which entries survive the count and size caps does not depend on
    /// dictionary iteration order. Host metadata is capped so that reserved
    /// keys (`sdk`, `platform`, `submittedAt`) always survive.
    ///
    /// - Parameters:
    ///   - metadata: Host-provided metadata key-value pairs.
    ///   - reserved: SDK-reserved metadata that must survive key-count eviction.
    /// - Returns: Sanitized and bounded metadata dictionary respecting PRIV-01.
    static func sanitize(
        _ metadata: [String: String],
        reserved: [String: String] = [:]
    ) -> [String: String] {
        var effectiveReserved: [String: String] = [:]
        for key in reservedKeyNames {
            if let value = reserved[key] ?? metadata[key] {
                effectiveReserved[key] = value
            }
        }
        for (key, value) in reserved where isValidKey(key) && effectiveReserved[key] == nil {
            effectiveReserved[key] = isCredentialKey(key) ? redactedValue : String(value.prefix(maxValueLength))
        }

        let maxHostKeys = max(0, maxKeys - effectiveReserved.count)

        var sanitized: [String: String] = [:]
        for (key, value) in metadata.sorted(by: { $0.key < $1.key }) {
            guard !effectiveReserved.keys.contains(key) else { continue }
            guard sanitized.count < maxHostKeys, isValidKey(key) else { continue }
            sanitized[key] = isCredentialKey(key) ? redactedValue : String(value.prefix(maxValueLength))
        }

        for (key, value) in effectiveReserved.sorted(by: { $0.key < $1.key }) {
            guard sanitized.count < maxKeys, isValidKey(key) else { continue }
            sanitized[key] = isCredentialKey(key) ? redactedValue : String(value.prefix(maxValueLength))
        }

        while serializedByteCount(of: sanitized) > maxTotalBytes {
            let hostKeyToDrop = sanitized.keys.filter { !effectiveReserved.keys.contains($0) }.min()
            if let dropped = hostKeyToDrop ?? sanitized.keys.min() {
                sanitized.removeValue(forKey: dropped)
            } else {
                break
            }
        }

        return sanitized
    }

    static func isValidKey(_ key: String) -> Bool {
        guard (1...64).contains(key.count) else { return false }
        // ASCII only, mirroring the server pattern `[A-Za-z0-9_.:-]`.
        return key.allSatisfy { character in
            guard character.isASCII else { return false }
            return character.isLetter || character.isNumber
                || character == "_" || character == "." || character == ":" || character == "-"
        }
    }

    static func normalizedKey(_ key: String) -> String {
        let range = NSRange(key.startIndex..<key.endIndex, in: key)
        let hyphenated = camelCaseRegex.stringByReplacingMatches(
            in: key,
            options: [],
            range: range,
            withTemplate: "$1-$2"
        )
        return hyphenated.lowercased()
    }

    static func isCredentialKey(_ key: String) -> Bool {
        let normalized = normalizedKey(key)
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        return sensitiveKeyRegex.firstMatch(in: normalized, options: [], range: range) != nil
    }

    private static func serializedByteCount(of metadata: [String: String]) -> Int {
        guard let data = try? JSONEncoder().encode(metadata) else { return 0 }
        return data.count
    }
}
