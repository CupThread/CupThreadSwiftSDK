import Foundation

// MARK: - FeedbackClient upload-session extension

extension FeedbackClient {

    /// Creates an upload session, pre-allocating one slot per file.
    ///
    /// Anonymous callers must present an `X-User-Token` — the session is
    /// always bound to an uploader identity, and feedback submission must
    /// later present the same identity. When `userToken` is `nil`, the SDK
    /// falls back to the client's app-key-scoped store so anonymous flows keep a
    /// stable identity. Authenticated callers attach the client's bearer token
    /// via the configured `authenticationProvider`.
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
        await applyBearerToken(to: &request)
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

        var request = try uploadRequest(
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

        let request = try uploadRequest(
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
    ) throws -> URLRequest {
        var request = URLRequest(url: try uploadURL(from: slot.uploadUrl))
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
        let resolvedDownload = resolvedDownloadURL(from: uploaded?.downloadUrl)
        let defaultUploadURL = (try? uploadURL(from: slot.uploadUrl)) ??
            configuration.baseURL.appending(path: "/api/v1/uploads")

        return FeedbackAttachment(
            kind: mimeType.hasPrefix("image/") ? .image : .r2,
            uploadId: uploadId,
            key: uploadId,
            url: resolvedDownload ?? defaultUploadURL,
            filename: uploaded?.filename ?? filename ?? slot.clientFileId,
            mimeType: mimeType,
            size: uploaded?.sizeBytes ?? fallbackSize
        )
    }

    private func fileSize(at fileURL: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        return attributes[.size] as? Int ?? 0
    }

    /// Resolves and validates an upload slot URL against the configured base URL.
    ///
    /// Accepts:
    /// - `nil` or empty string: defaults to `configuration.baseURL.appending(path: "/api/v1/uploads")`.
    /// - Relative path: resolved against `configuration.baseURL`.
    /// - Same-host absolute `http`/`https` URL matching `configuration.baseURL.host` (case-insensitive).
    ///
    /// Throws ``FeedbackClientError/invalidResponse`` on off-origin absolute URLs,
    /// protocol-relative URLs (`//`), or disallowed schemes.
    func uploadURL(from uploadUrl: String?) throws -> URL {
        if let uploadUrl, !uploadUrl.isEmpty {
            let trimmed = uploadUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return configuration.baseURL.appending(path: "/api/v1/uploads")
            }
            if trimmed.hasPrefix("//") {
                throw FeedbackClientError.invalidResponse
            }
            if let candidate = URL(string: trimmed), candidate.scheme != nil {
                guard let scheme = candidate.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else {
                    throw FeedbackClientError.invalidResponse
                }
                if configuration.baseURL.scheme?.lowercased() == "https", scheme != "https" {
                    throw FeedbackClientError.invalidResponse
                }
                guard let candidateHost = candidate.host?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !candidateHost.isEmpty,
                      let baseHost = configuration.baseURL.host?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !baseHost.isEmpty,
                      candidateHost.caseInsensitiveCompare(baseHost) == .orderedSame else {
                    throw FeedbackClientError.invalidResponse
                }
                let basePort = configuration.baseURL.port ??
                    (configuration.baseURL.scheme?.lowercased() == "http" ? 80 : 443)
                let candidatePort = candidate.port ?? (scheme == "http" ? 80 : 443)
                guard basePort == candidatePort else {
                    throw FeedbackClientError.invalidResponse
                }
                return candidate
            }
            return configuration.baseURL.appending(path: trimmed)
        }
        return configuration.baseURL.appending(path: "/api/v1/uploads")
    }

    /// Validates an untrusted `downloadUrl` string returned by an upload PUT response:
    /// - Accepts relative paths resolved against `configuration.baseURL`.
    /// - Accepts absolute `http`/`https` URLs whose host matches `configuration.baseURL.host`
    ///   or shares its root domain (e.g. CDN hosts or apex domain).
    /// - Returns `nil` for off-origin, protocol-relative, or disallowed-scheme URLs.
    private func resolvedDownloadURL(from downloadUrl: String?) -> URL? {
        guard let downloadUrl else { return nil }
        let trimmed = downloadUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { return nil }

        if let candidate = URL(string: trimmed), candidate.scheme != nil {
            guard let scheme = candidate.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return nil
            }
            if configuration.baseURL.scheme?.lowercased() == "https", scheme != "https" {
                return nil
            }
            guard let candidateHost = candidate.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !candidateHost.isEmpty,
                  let baseHost = configuration.baseURL.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !baseHost.isEmpty else {
                return nil
            }
            if isAllowedDownloadHost(candidateHost, baseHost: baseHost) {
                return candidate
            }
            return nil
        }

        return configuration.baseURL.appending(path: trimmed)
    }
}
