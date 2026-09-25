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
        /// Upload URL as returned by the server (absolute, or a path to
        /// resolve against the client's base URL).
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

// MARK: - FeedbackClient upload-session extension

extension FeedbackClient {

    /// Creates an upload session, pre-allocating one slot per file.
    ///
    /// Anonymous callers must present an `X-User-Token` — the session is
    /// always bound to an uploader identity, and feedback submission must
    /// later present the same identity. When `userToken` is `nil`, the SDK
    /// falls back to the client's app-key-scoped store so anonymous flows keep a
    /// stable identity.
    ///
    /// - Parameters:
    ///   - files: One specification per file to pre-allocate (1–8).
    ///   - userToken: Anonymous end-user token sent as `X-User-Token`.
    ///   - turnstileToken: Optional Turnstile token for apps that require one.
    ///     When `nil`, the client's `turnstileTokenProvider` is consulted as a
    ///     fallback, so one provider configuration covers attachments and
    ///     submission alike.
    /// - Returns: The session, including bearer token and pre-allocated slots.
    /// - Throws: ``FeedbackClientError/uploaderIdentityRequired`` when no
    ///   identity could be presented, ``FeedbackClientError/rateLimited`` on
    ///   HTTP 429, or ``FeedbackClientError/unexpectedStatus(code:message:requestId:)``
    ///   / ``FeedbackClientError/invalidResponse`` for other failures.
    public func createUploadSession(
        files: [FeedbackUploadFileSpec],
        userToken: String?,
        turnstileToken: String? = nil
    ) async throws -> FeedbackUploadSession {
        struct CreateSessionPayload: Encodable, Sendable {
            let appKey: String
            let purpose: String
            let turnstileToken: String?
            let files: [FeedbackUploadFileSpec]
        }

        var request = URLRequest(url: configuration.baseURL.appending(path: "/api/v1/uploads/sessions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyCorrelationHeaders(
            userToken: resolvedIdentity(userToken),
            requestID: nextRequestID(),
            to: &request
        )
        var effectiveTurnstileToken = turnstileToken?.nilIfEmpty
        if effectiveTurnstileToken == nil {
            effectiveTurnstileToken = await resolvedTurnstileToken()
        }
        request.httpBody = try encoder.encode(CreateSessionPayload(
            appKey: configuration.appKey,
            purpose: "feedback_attachment",
            turnstileToken: effectiveTurnstileToken,
            files: files
        ))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        try validateResponse(httpResponse, data: data, accepted: [201])
        return try decoder.decode(FeedbackUploadSession.self, from: data)
    }

    /// Uploads a file into a pre-allocated session slot by streaming its
    /// bytes to `PUT /api/v1/uploads/{uploadId}` with the session's bearer
    /// token.
    ///
    /// - Parameters:
    ///   - data: The raw file bytes.
    ///   - contentType: The file's MIME type; the server verifies it against
    ///     the bytes' magic content (`415` on mismatch).
    ///   - session: The session the slot belongs to.
    ///   - slot: The slot to fill; defaults to the session's first slot.
    ///   - filename: Name recorded on the returned attachment; defaults to
    ///     the slot's `clientFileId`.
    /// - Returns: The uploaded attachment reference, carrying the ``FeedbackAttachment/uploadId``
    ///   needed for feedback submission.
    /// - Throws: ``FeedbackClientError/payloadTooLarge`` (HTTP 413),
    ///   ``FeedbackClientError/unsupportedMediaType`` (HTTP 415),
    ///   ``FeedbackClientError/rateLimited`` (HTTP 429), or
    ///   ``FeedbackClientError/unexpectedStatus(code:message:requestId:)`` /
    ///   ``FeedbackClientError/invalidResponse`` for other failures.
    public func uploadAttachment(
        data: Data,
        contentType: String,
        session uploadSession: FeedbackUploadSession,
        slot: FeedbackUploadSession.File? = nil,
        filename: String? = nil
    ) async throws -> FeedbackAttachment {
        guard let slot = slot ?? uploadSession.files.first else {
            throw FeedbackClientError.unreadableUploadResponse
        }
        if let limit = uploadSession.effectiveMaxSizeBytes(for: slot), data.count > limit {
            throw FeedbackClientError.payloadTooLarge(message: nil)
        }

        var request = uploadRequest(
            slot: slot,
            sessionToken: uploadSession.session.sessionToken,
            contentType: contentType
        )
        request.httpBody = data

        let (responseData, response) = try await session.data(for: request)
        try validateUploadResponse(response, data: responseData)
        return finalizedAttachment(
            from: responseData,
            contentType: contentType,
            slot: slot,
            fallbackSize: data.count,
            filename: filename
        )
    }

    /// Uploads a file into a pre-allocated session slot by streaming it from
    /// disk to `PUT /api/v1/uploads/{uploadId}` with the session's bearer
    /// token.
    ///
    /// The body is handed to URLSession as a file URL (`upload(for:fromFile:)`),
    /// so the bytes are streamed off disk in bounded chunks instead of being
    /// buffered in memory for the whole request — a large attachment never
    /// exists twice in RAM during the network round-trip. Prefer this variant
    /// for large files and memory-constrained hosts (app extensions); the
    /// ``uploadAttachment(data:contentType:session:slot:filename:)`` variant
    /// stays convenient for bytes already in memory.
    ///
    /// - Parameters:
    ///   - fileURL: URL of the file to upload; its bytes are sent unmodified.
    ///   - contentType: The file's MIME type; the server verifies it against
    ///     the bytes' magic content (`415` on mismatch).
    ///   - session: The session the slot belongs to.
    ///   - slot: The slot to fill; defaults to the session's first slot.
    ///   - filename: Name recorded on the returned attachment; defaults to
    ///     the slot's `clientFileId`.
    /// - Returns: The uploaded attachment reference, carrying the ``FeedbackAttachment/uploadId``
    ///   needed for feedback submission.
    /// - Throws: ``FeedbackClientError/payloadTooLarge`` (HTTP 413),
    ///   ``FeedbackClientError/unsupportedMediaType`` (HTTP 415),
    ///   ``FeedbackClientError/rateLimited`` (HTTP 429), or
    ///   ``FeedbackClientError/unexpectedStatus(code:message:requestId:)`` /
    ///   ``FeedbackClientError/invalidResponse`` for other failures.
    public func uploadAttachment(
        fileURL: URL,
        contentType: String,
        session uploadSession: FeedbackUploadSession,
        slot: FeedbackUploadSession.File? = nil,
        filename: String? = nil
    ) async throws -> FeedbackAttachment {
        guard let slot = slot ?? uploadSession.files.first else {
            throw FeedbackClientError.unreadableUploadResponse
        }
        let fileSize = try fileSize(at: fileURL)
        if let limit = uploadSession.effectiveMaxSizeBytes(for: slot), fileSize > limit {
            throw FeedbackClientError.payloadTooLarge(message: nil)
        }

        let request = uploadRequest(
            slot: slot,
            sessionToken: uploadSession.session.sessionToken,
            contentType: contentType
        )
        let (responseData, response) = try await session.upload(for: request, fromFile: fileURL)
        try validateUploadResponse(response, data: responseData)
        return finalizedAttachment(
            from: responseData,
            contentType: contentType,
            slot: slot,
            fallbackSize: fileSize,
            filename: filename
        )
    }

    /// Uploads one file end-to-end: creates a session bound to the end-user
    /// identity, then streams the bytes into the session's first slot.
    ///
    /// When `userToken` is `nil`, the SDK falls back to the client's
    /// app-key-scoped store so anonymous flows keep a stable identity across session creation and
    /// feedback submission.
    ///
    /// - Parameters:
    ///   - data: The raw file bytes.
    ///   - filename: Name shown in the console, e.g. `"screenshot.png"`.
    ///   - mimeType: The file's MIME type, e.g. `"image/png"`. Only PNG,
    ///     JPEG, WebP, and GIF are accepted by the server.
    ///   - userToken: Anonymous token; when given it is sent as `X-User-Token`.
    /// - Returns: The uploaded attachment, carrying its `uploadId` for
    ///   `FeedbackDraft.attachments`.
    /// - Throws: ``FeedbackClientError/unsupportedMediaType`` when the type
    ///   is not accepted, ``FeedbackClientError/payloadTooLarge`` when it
    ///   exceeds the slot limit, ``FeedbackClientError/uploaderIdentityRequired``
    ///   when no identity could be presented, or
    ///   ``FeedbackClientError/unexpectedStatus(code:message:requestId:)`` for
    ///   other server failures.
    public func uploadAttachment(
        data: Data,
        filename: String,
        mimeType: String,
        userToken: String? = nil
    ) async throws -> FeedbackAttachment {
        let uploadSession = try await createUploadSession(
            files: [FeedbackUploadFileSpec(
                clientFileId: "file-1",
                filename: filename,
                contentType: mimeType,
                sizeBytes: data.count
            )],
            userToken: userToken
        )
        return try await uploadAttachment(
            data: data,
            contentType: mimeType,
            session: uploadSession,
            filename: filename
        )
    }

    /// Uploads one file end-to-end by streaming it from disk: creates a
    /// session bound to the end-user identity, then streams the file's bytes
    /// into the session's first slot via `upload(for:fromFile:)`, so the
    /// attachment is never fully buffered in RAM during the network
    /// round-trip.
    ///
    /// When `userToken` is `nil`, the SDK falls back to the client's
    /// app-key-scoped store so anonymous flows keep a stable identity across session creation and
    /// feedback submission.
    ///
    /// - Parameters:
    ///   - fileURL: URL of the file to upload; its bytes are sent unmodified.
    ///   - filename: Name shown in the console, e.g. `"screenshot.png"`.
    ///   - mimeType: The file's MIME type, e.g. `"image/png"`. Only PNG,
    ///     JPEG, WebP, and GIF are accepted by the server.
    ///   - userToken: Anonymous token; when given it is sent as `X-User-Token`.
    /// - Returns: The uploaded attachment, carrying its `uploadId` for
    ///   `FeedbackDraft.attachments`.
    /// - Throws: ``FeedbackClientError/unsupportedMediaType`` when the type
    ///   is not accepted, ``FeedbackClientError/payloadTooLarge`` when it
    ///   exceeds the slot limit, ``FeedbackClientError/uploaderIdentityRequired``
    ///   when no identity could be presented, or
    ///   ``FeedbackClientError/unexpectedStatus(code:message:requestId:)`` for
    ///   other server failures.
    public func uploadAttachment(
        fileURL: URL,
        filename: String,
        mimeType: String,
        userToken: String? = nil
    ) async throws -> FeedbackAttachment {
        let uploadSession = try await createUploadSession(
            files: [FeedbackUploadFileSpec(
                clientFileId: "file-1",
                filename: filename,
                contentType: mimeType,
                sizeBytes: try fileSize(at: fileURL)
            )],
            userToken: userToken
        )
        return try await uploadAttachment(
            fileURL: fileURL,
            contentType: mimeType,
            session: uploadSession,
            filename: filename
        )
    }

    // MARK: Helpers

    /// Builds the `PUT /api/v1/uploads/{uploadId}` request for a slot.
    private func uploadRequest(
        slot: FeedbackUploadSession.File,
        sessionToken: String,
        contentType: String
    ) -> URLRequest {
        var request = URLRequest(url: uploadURL(from: slot.uploadUrl))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(nextRequestID(), forHTTPHeaderField: "X-Request-Id")
        request.setValue(Self.sdkVersion, forHTTPHeaderField: "X-SDK-Version")
        return request
    }

    private func validateUploadResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }
        try validateResponse(httpResponse, data: data, accepted: [200])
    }

    /// Decodes the finalized upload object leniently, falling back to
    /// slot/local facts for anything the server omits.
    private func finalizedAttachment(
        from responseData: Data,
        contentType: String,
        slot: FeedbackUploadSession.File,
        fallbackSize: Int,
        filename: String?
    ) -> FeedbackAttachment {
        struct UploadedFile: Decodable, Sendable {
            let uploadId: String?
            let filename: String?
            let contentType: String?
            let sizeBytes: Int?
            let downloadUrl: String?
        }
        let uploaded = try? decoder.decode(UploadedFile.self, from: responseData)
        let uploadId = uploaded?.uploadId ?? slot.uploadId
        let mimeType = uploaded?.contentType ?? contentType
        let resolvedDownloadURL = uploaded?.downloadUrl
            .flatMap { $0.isEmpty ? nil : URL(string: $0) }

        return FeedbackAttachment(
            kind: mimeType.hasPrefix("image/") ? .image : .r2,
            uploadId: uploadId,
            key: uploadId,
            url: resolvedDownloadURL ?? uploadURL(from: slot.uploadUrl),
            filename: uploaded?.filename ?? filename ?? slot.clientFileId,
            mimeType: mimeType,
            size: uploaded?.sizeBytes ?? fallbackSize
        )
    }

    private func fileSize(at fileURL: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        return attributes[.size] as? Int ?? 0
    }

    private func uploadURL(from uploadUrl: String?) -> URL {
        if let uploadUrl, !uploadUrl.isEmpty, let url = URL(string: uploadUrl), url.scheme != nil {
            return url
        }
        let base = configuration.baseURL
        if let uploadUrl, !uploadUrl.isEmpty {
            return base.appending(path: uploadUrl)
        }
        return base.appending(path: "/api/v1/uploads")
    }
}
