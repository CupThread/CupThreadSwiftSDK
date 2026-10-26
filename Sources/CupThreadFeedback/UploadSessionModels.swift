import Foundation

// MARK: - Upload session models (POST /api/v1/uploads/sessions)

/// One file to pre-allocate in an upload session, as sent to
/// `POST /api/v1/uploads/sessions`.
public struct FeedbackUploadFileSpec: Encodable, Equatable, Sendable {
    /// Caller-chosen id echoed back on the session's file slots, so slots can
    /// be matched to inputs when creating several in one call.
    public var clientFileId: String
    /// File name reported to the server, e.g. `"screenshot.png"`.
    public var filename: String
    /// Declared MIME type, e.g. `"image/png"`. The server verifies it against
    /// the uploaded bytes' magic bytes.
    public var contentType: String
    /// Declared size in bytes. Must be at least
    /// ``UploadSessionLimits/minFileSizeBytes``: the session endpoint can only
    /// answer a zero-byte or negative declaration with `400`, so
    /// ``FeedbackClient/createUploadSession(files:userToken:turnstileToken:)``
    /// refuses such a specification locally (issue #611). The server's
    /// per-file *upper* limit is enforced on the streamed bytes and published
    /// per session (``FeedbackUploadSession/effectiveMaxSizeBytes(for:)``), so
    /// the floor is the only size bound the client can decide up front.
    public var sizeBytes: Int

    /// Creates a file specification for an upload session.
    /// - Parameters:
    ///   - clientFileId: Caller-chosen id echoed back on the matching slot.
    ///   - filename: File name reported to the server.
    ///   - contentType: Declared MIME type.
    ///   - sizeBytes: Declared size in bytes; at least
    ///     ``UploadSessionLimits/minFileSizeBytes``.
    public init(clientFileId: String, filename: String, contentType: String, sizeBytes: Int) {
        self.clientFileId = clientFileId
        self.filename = filename
        self.contentType = contentType
        self.sizeBytes = sizeBytes
    }
}

/// The grammar the upload-session bearer token must satisfy before it may
/// reach the `Authorization` header of a slot PUT (issue #593).
///
/// `sessionToken` is server-controlled: it arrives in the
/// `POST /api/v1/uploads/sessions` response body and is replayed by the
/// client into a new request header. That is the same trust class as the
/// response-echoed `X-Request-Id` (SEC-12), and it is the last header
/// interpolation sink that had no validation — caller-supplied tokens were
/// already hardened by `validatedUserToken` (SEC-25/SEC-26/SEC-30, #433,
/// #435, #497). The grammar rejects anything that could smuggle header lines
/// (control characters, which subsume CR/LF/TAB/NUL), anything blank, and
/// anything oversized, so a corrupted or hostile response fails closed as a
/// typed ``FeedbackClientError/invalidResponse`` instead of being emitted
/// verbatim onto the wire.
enum UploadSessionTokenGrammar {
    /// The maximum bearer-token length, in UTF-8 bytes. Generous for an
    /// opaque bearer (1 KiB) while bounding the size of any single header
    /// line. Measured in bytes rather than characters: one `Character` can
    /// carry unbounded combining scalars, so a grapheme count would not bound
    /// the `Authorization` header's wire size at all.
    static let maxByteCount = 1024

    /// Whether `value` can be presented as the slot PUT's bearer token.
    /// Expects an untrimmed value; surrounding whitespace is part of the
    /// check so a padded-but-otherwise-valid token is accepted trimmed
    /// (same semantics as `validatedUserToken`).
    static func isValid(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: \.isNewline),
              trimmed.utf8.count <= maxByteCount else {
            return false
        }
        // Control characters (C0/C1) cover every header-injection vector —
        // CR, LF, TAB, NUL, and the rest — while leaving exotic but legal
        // opaque-token characters alone.
        return !trimmed.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// The trimmed token when ``isValid(_:)`` holds, otherwise `nil`.
    static func validated(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValid(value) ? trimmed : nil
    }
}

/// Client-side bounds for upload-session creation (API-28, issue #611).
///
/// `POST /api/v1/uploads/sessions` accepts 1–8 `files` per session, each
/// declaring at least one byte, and can only answer anything else with
/// `400`, so
/// ``FeedbackClient/createUploadSession(files:userToken:turnstileToken:)``
/// refuses out-of-bounds payloads locally — before a Turnstile token is
/// consumed or any request is sent — instead of burning a single-use
/// challenge on a guaranteed-failing round trip. The server validates the
/// payload as one object, so one bad specification fails the whole array
/// and a partial session is never created.
public enum UploadSessionLimits: Sendable {
    /// The file-count range the session endpoint accepts: one specification
    /// per pre-allocated slot, at least one file, at most eight — the same
    /// cap the feedback submission endpoint enforces on referenced
    /// `uploadId`s, published for that endpoint as
    /// ``FeedbackSubmissionLimits/maxAttachmentCount`` (#613). The two
    /// bounds are separate schema properties with their own parity
    /// tripwires, so each is declared where its endpoint is defined.
    public static let allowedFileCountRange = 1...8

    /// The smallest declared file size the session endpoint accepts
    /// (`CreateUploadSessionFileInput.sizeBytes` `minimum: 1`). A
    /// ``FeedbackUploadFileSpec/sizeBytes`` below this floor is refused
    /// locally with ``FeedbackClientError/invalidResponse``, the same
    /// rejection as an out-of-range file count. The per-file *upper* bound
    /// is a session property the server enforces on the streamed bytes
    /// (``FeedbackUploadSession/effectiveMaxSizeBytes(for:)``), so this floor
    /// is the only size bound the client can decide before a session exists.
    public static let minFileSizeBytes = 1
}

/// An upload session created via `POST /api/v1/uploads/sessions`.
///
/// Files are uploaded by streaming bytes to each slot's
/// `PUT /api/v1/uploads/{uploadId}` with the session's bearer token, and the
/// returned ``FeedbackUploadSessionFile/uploadId`` values are then attached
/// to a ``FeedbackDraft`` for submission.
public struct FeedbackUploadSession: Decodable, Equatable, Sendable {
    /// Session metadata.
    public struct Info: Decodable, Equatable, Sendable {
        /// Server-assigned session id.
        public let sessionId: String
        /// Bearer token presented to `PUT /api/v1/uploads/{uploadId}`.
        public let sessionToken: String
        /// ISO-8601 expiry of the session; uploads must finish before it.
        public let expiresAt: String?
        /// Server-side per-file size limit for this session, when given.
        public let maxFileSizeBytes: Int?
        /// Maximum number of files in this session, when given.
        public let maxFiles: Int?

        private enum CodingKeys: String, CodingKey {
            case sessionId
            case sessionToken
            case expiresAt
            case maxFileSizeBytes
            case maxFiles
        }

        /// Decodes the session info, refusing any `sessionToken` outside
        /// ``UploadSessionTokenGrammar`` (#593). Enforcement lives at the
        /// decode boundary — the only place a session enters the process —
        /// so an invalid token can never propagate to a second consumer,
        /// and `decodeSuccess` surfaces the failure as the typed
        /// ``FeedbackClientError/invalidResponse`` before any upload PUT is
        /// built.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionId = try container.decode(String.self, forKey: .sessionId)
            let rawSessionToken = try container.decode(String.self, forKey: .sessionToken)
            guard let sessionToken = UploadSessionTokenGrammar.validated(rawSessionToken) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .sessionToken,
                    in: container,
                    debugDescription: """
                    sessionToken is blank, newline- or control-character-bearing, \
                    or longer than \(UploadSessionTokenGrammar.maxByteCount) UTF-8 bytes (#593)
                    """
                )
            }
            self.sessionToken = sessionToken
            expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
            maxFileSizeBytes = try container.decodeIfPresent(Int.self, forKey: .maxFileSizeBytes)
            maxFiles = try container.decodeIfPresent(Int.self, forKey: .maxFiles)
        }

        /// Memberwise initializer preserved for in-module construction
        /// (tests, synthetic sessions for limit math). The network trust
        /// boundary is ``init(from:)``, which is the only initializer a
        /// decoded — server-controlled — session can pass through.
        init(
            sessionId: String,
            sessionToken: String,
            expiresAt: String?,
            maxFileSizeBytes: Int?,
            maxFiles: Int?
        ) {
            self.sessionId = sessionId
            self.sessionToken = sessionToken
            self.expiresAt = expiresAt
            self.maxFileSizeBytes = maxFileSizeBytes
            self.maxFiles = maxFiles
        }
    }

    /// One pre-allocated file slot.
    public struct File: Decodable, Equatable, Sendable {
        /// The caller's ``FeedbackUploadFileSpec/clientFileId`` echoed back.
        public let clientFileId: String?
        /// Id identifying this upload; passed to feedback submission via
        /// ``FeedbackDraft/attachments``.
        public let uploadId: String
        /// Upload URL as returned by the server (relative path or same-host absolute URL
        /// matching the client's base URL; absolute off-origin URLs are rejected for security).
        public let uploadUrl: String?
        /// Per-file size limit for this slot, when given.
        public let maxSizeBytes: Int?
    }

    /// Session metadata, including the bearer token for the upload calls.
    public let session: Info
    /// Pre-allocated slots, in the order the files were requested.
    public let files: [File]
}

extension FeedbackUploadSession {
    /// Returns the effective maximum upload size in bytes for a slot by
    /// taking the minimum of the slot's limit and the session-wide limit,
    /// or whichever limit is specified if only one is present.
    ///
    /// - Parameter slot: The slot whose limits to evaluate. When `nil`, defaults
    ///   to the session's first slot.
    /// - Returns: The effective upper bound in bytes, or `nil` if neither
    ///   the slot nor the session specifies a limit.
    public func effectiveMaxSizeBytes(for slot: File? = nil) -> Int? {
        let resolvedSlot = slot ?? files.first
        switch (resolvedSlot?.maxSizeBytes, session.maxFileSizeBytes) {
        case let (.some(slotLimit), .some(sessionLimit)):
            return min(slotLimit, sessionLimit)
        case let (.some(slotLimit), .none):
            return slotLimit
        case let (.none, .some(sessionLimit)):
            return sessionLimit
        case (.none, .none):
            return nil
        }
    }
}
