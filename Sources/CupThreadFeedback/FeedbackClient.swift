import Foundation

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}

/// Connection settings for a ``FeedbackClient``.
///
/// Create one configuration per CupThread app and share it across clients:
///
/// ```swift
/// let configuration = FeedbackClientConfiguration(
///     baseURL: URL(string: "https://api.cupthread.com")!,
///     appKey: "app_xxx"   // from the CupThread developer console
/// )
/// ```
public struct FeedbackClientConfiguration: Equatable, Sendable {
    /// The API root, without a trailing path — normally `https://api.cupthread.com`.
    ///
    /// All endpoints are appended to this URL, e.g. `…/api/v1/feedback`.
    public let baseURL: URL

    /// The app key identifying your app in CupThread (starts with `app_`).
    ///
    /// Sent with most requests and embedded in public endpoint paths such as
    /// `GET /api/v1/public/config/{appKey}`.
    public let appKey: String

    /// The platform value reported with feedback submissions.
    ///
    /// Defaults to ``FeedbackPlatform/current``, which matches the OS the SDK
    /// is running on. Override it when the app reports a custom platform —
    /// e.g. a Mac Catalyst build that should count as `.macos`.
    public let defaultPlatform: FeedbackPlatform

    /// Creates a configuration for a CupThread app.
    /// - Parameters:
    ///   - baseURL: The API root, normally `https://api.cupthread.com`.
    ///   - appKey: Your app's key from the CupThread developer console.
    ///   - defaultPlatform: The platform reported with feedback submissions.
    ///     Defaults to the OS the SDK is running on.
    public init(
        baseURL: URL,
        appKey: String,
        defaultPlatform: FeedbackPlatform = FeedbackPlatform.current
    ) {
        self.baseURL = baseURL
        self.appKey = appKey
        self.defaultPlatform = defaultPlatform
    }
}

/// Errors thrown by ``FeedbackClient`` network calls.
public enum FeedbackClientError: LocalizedError, Sendable {
    /// The server response could not be interpreted as HTTP.
    case invalidResponse
    /// The upload endpoint returned a success response (200, 201, or 202)
    /// whose body could not be decoded.
    case unreadableUploadResponse
    /// The endpoint requires a signed-in user — e.g. the app's changelog
    /// is restricted and anonymous access is disabled (`401 authentication_required`).
    case authenticationRequired
    /// The server answered with a status the SDK does not handle. `message`
    /// carries the raw response body for debugging.
    case unexpectedStatus(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The feedback server returned an invalid response."
        case .unreadableUploadResponse:
            return "The feedback server returned an unreadable upload response."
        case .authenticationRequired:
            return "These updates are only available to signed-in users."
        case .unexpectedStatus(let code, let message):
            return "The feedback request failed (\(code)): \(message)"
        }
    }
}

private struct FeedbackSubmissionPayload: Codable, Sendable {
    let appKey: String
    let title: String
    let description: String
    let reporterName: String?
    let reporterEmail: String?
    let platform: FeedbackPlatform
    let appVersion: String?
    let buildNumber: String?
    let metadata: [String: String]
    let attachments: [AttachmentPayload]
}

private struct AttachmentPayload: Codable, Sendable {
    let kind: String
    let key: String
    let url: URL
    let filename: String?
    let mimeType: String?
    let size: Int?
}

private struct UploadedAttachmentResponse: Codable, Sendable {
    let kind: String
    let key: String
    let url: URL
    let filename: String?
    let mimeType: String?
    let size: Int?
}

/// The HTTP client for the CupThread feedback API.
///
/// One client serves every SDK surface — feedback, feature requests, roadmap,
/// and changelog. Create it once with a ``FeedbackClientConfiguration`` and
/// share it freely; the client is stateless and `Sendable`.
///
/// ```swift
/// let client = FeedbackClient(
///     configuration: FeedbackClientConfiguration(
///         baseURL: URL(string: "https://api.cupthread.com")!,
///         appKey: "app_xxx"
///     )
/// )
/// ```
///
/// The views (``FeedbackComposerView``, ``FeatureRequestsView``,
/// ``RoadmapBoardView``, ``WhatsNewView``) use the same client, so you can mix
/// ready-made UI with direct calls like ``submit(_:userToken:)``.
public struct FeedbackClient: Sendable {
    /// The configuration this client was created with.
    public let configuration: FeedbackClientConfiguration
    let session: URLSession
    let encoder: JSONEncoder
    let decoder: JSONDecoder

    /// Creates a client for a CupThread app.
    /// - Parameters:
    ///   - configuration: API root, app key, and default reported platform.
    ///   - session: The URL session requests run in. Override to install a
    ///     custom `URLProtocol` (tests) or custom timeouts; defaults to `.shared`.
    public init(
        configuration: FeedbackClientConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    /// Submits a feedback draft.
    ///
    /// Titles and descriptions are trimmed; empty contact fields, version
    /// strings, and attachment lists are omitted from the payload. The SDK
    /// adds `sdk`, `platform`, and `submittedAt` metadata automatically.
    ///
    /// ```swift
    /// var draft = FeedbackDraft.autofilled()
    /// draft.title = "Sync drops edits"
    /// draft.description = "Editing while offline loses my last change."
    /// let result = try await client.submit(draft, userToken: token)
    /// ```
    ///
    /// - Parameters:
    ///   - draft: The feedback to send. See ``FeedbackDraft``.
    ///   - userToken: Optional anonymous token (UUID string). When provided it is
    ///     sent as `X-User-Token` so the backend can link the submission to an end-user identity.
    /// - Returns: The server's receipt, including the submission id and any warning.
    /// - Throws: ``FeedbackClientError/unexpectedStatus(code:message:)`` when the
    ///   server rejects the request, or ``FeedbackClientError/invalidResponse``
    ///   when the response cannot be interpreted.
    public func submit(
        _ draft: FeedbackDraft,
        userToken: String? = nil
    ) async throws -> FeedbackSubmissionResult {
        let payload = FeedbackSubmissionPayload(
            appKey: configuration.appKey,
            title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: draft.description.trimmingCharacters(in: .whitespacesAndNewlines),
            reporterName: draft.reporterName.nilIfEmpty,
            reporterEmail: draft.reporterEmail.nilIfEmpty,
            platform: draft.platform,
            appVersion: draft.appVersion.nilIfEmpty,
            buildNumber: draft.buildNumber.nilIfEmpty,
            metadata: draft.metadata.merging(defaultMetadata(from: draft)) { current, _ in current },
            attachments: draft.attachments.map {
                AttachmentPayload(
                    kind: $0.kind.rawValue,
                    key: $0.key,
                    url: $0.url,
                    filename: $0.filename,
                    mimeType: $0.mimeType,
                    size: $0.size
                )
            }
        )

        var request = URLRequest(url: configuration.baseURL.appending(path: "/api/v1/feedback"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyUserToken(userToken, to: &request)
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }

        try validateStatus(httpResponse.statusCode, accepted: [200, 202], data: data)

        return try decoder.decode(FeedbackSubmissionResult.self, from: data)
    }

    /// Uploads a file and returns the attachment reference to embed in a ``FeedbackDraft``.
    ///
    /// Image MIME types post to the image endpoint (`POST /api/v1/uploads/images`);
    /// everything else posts to object storage (`POST /api/v1/uploads/r2`).
    /// The returned ``FeedbackAttachment`` is already shaped for
    /// `FeedbackDraft.attachments`.
    ///
    /// - Parameters:
    ///   - data: The raw file bytes.
    ///   - filename: Name shown in the console, e.g. `"screenshot.png"`.
    ///   - mimeType: The file's MIME type, e.g. `"image/png"`.
    ///   - preferredKind: Forces the upload endpoint instead of inferring it
    ///     from `mimeType`. `nil` (the default) routes `image/*` to the image
    ///     endpoint and everything else to object storage.
    ///   - userToken: Optional anonymous token; when given it is sent as
    ///     `X-User-Token` so uploads link to the end-user identity.
    /// - Returns: The uploaded attachment, including its storage `key` and `url`.
    /// - Throws: ``FeedbackClientError/unexpectedStatus(code:message:)`` when the
    ///   server rejects the upload — typically because the file exceeds the
    ///   app's `maxAttachmentBytes` limit — or when the server responds with an
    ///   unexpected HTTP status (successful responses accept HTTP 200, 201, and 202);
    ///   or ``FeedbackClientError/unreadableUploadResponse`` when the success
    ///   response cannot be decoded.
    public func uploadAttachment(
        data: Data,
        filename: String,
        mimeType: String,
        preferredKind: FeedbackAttachment.Kind? = nil,
        userToken: String? = nil
    ) async throws -> FeedbackAttachment {
        let endpointKind = preferredKind ?? (mimeType.hasPrefix("image/") ? .image : .r2)
        let endpoint = endpointKind == .image ? "/api/v1/uploads/images" : "/api/v1/uploads/r2"

        var request = URLRequest(url: configuration.baseURL.appending(path: endpoint))
        request.httpMethod = "POST"

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        applyUserToken(userToken, to: &request)
        request.httpBody = multipartFormData(
            boundary: boundary,
            appKey: configuration.appKey,
            filename: filename,
            mimeType: mimeType,
            fileData: data
        )

        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }

        try validateStatus(httpResponse.statusCode, accepted: [200, 201, 202], data: responseData)

        let uploaded = try decoder.decode(UploadedAttachmentResponse.self, from: responseData)
        guard let kind = FeedbackAttachment.Kind(rawValue: uploaded.kind) else {
            throw FeedbackClientError.unreadableUploadResponse
        }

        return FeedbackAttachment(
            kind: kind,
            key: uploaded.key,
            url: uploaded.url,
            filename: uploaded.filename,
            mimeType: uploaded.mimeType,
            size: uploaded.size
        )
    }

    private func multipartFormData(
        boundary: String,
        appKey: String,
        filename: String,
        mimeType: String,
        fileData: Data
    ) -> Data {
        var body = Data()

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"appKey\"\r\n\r\n")
        body.append("\(appKey)\r\n")
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(escapedMultipartFilename(filename))\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.append("\r\n")
        body.append("--\(boundary)--\r\n")

        return body
    }

    private func escapedMultipartFilename(_ filename: String) -> String {
        filename
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func defaultMetadata(from draft: FeedbackDraft) -> [String: String] {
        var metadata = draft.metadata
        metadata["sdk"] = "cupthread-apple"
        metadata["platform"] = draft.platform.rawValue
        metadata["submittedAt"] = ISO8601DateFormatter().string(from: .now)
        return metadata
    }

    private func applyUserToken(_ userToken: String?, to request: inout URLRequest) {
        if let userToken = userToken?.nilIfEmpty {
            request.setValue(userToken, forHTTPHeaderField: "X-User-Token")
        }
    }

    private func validateStatus(
        _ statusCode: Int,
        accepted: Set<Int>,
        data: Data
    ) throws {
        guard accepted.contains(statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw FeedbackClientError.unexpectedStatus(code: statusCode, message: message)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
