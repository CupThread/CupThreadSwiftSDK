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
    /// Declared size in bytes. The server enforces the session's per-file
    /// limit when the bytes are streamed.
    public var sizeBytes: Int

    /// Creates a file specification for an upload session.
    /// - Parameters:
    ///   - clientFileId: Caller-chosen id echoed back on the matching slot.
    ///   - filename: File name reported to the server.
    ///   - contentType: Declared MIME type.
    ///   - sizeBytes: Declared size in bytes.
    public init(clientFileId: String, filename: String, contentType: String, sizeBytes: Int) {
        self.clientFileId = clientFileId
        self.filename = filename
        self.contentType = contentType
        self.sizeBytes = sizeBytes
    }
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
