import Foundation

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}

public struct FeedbackClientConfiguration: Equatable, Sendable {
    public let baseURL: URL
    public let appKey: String
    public let defaultPlatform: FeedbackPlatform

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

public enum FeedbackClientError: LocalizedError, Sendable {
    case invalidResponse
    case unreadableUploadResponse
    /// The endpoint requires a signed-in user — e.g. the app's changelog
    /// is restricted and anonymous access is disabled (`401 authentication_required`).
    case authenticationRequired
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

public struct FeedbackClient: Sendable {
    public let configuration: FeedbackClientConfiguration
    let session: URLSession
    let encoder: JSONEncoder
    let decoder: JSONDecoder

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
    /// - Parameter userToken: Optional anonymous token (UUID string). When provided it is
    ///   sent as `X-User-Token` so the backend can link the submission to an end-user identity.
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
        if let userToken {
            request.setValue(userToken, forHTTPHeaderField: "X-User-Token")
        }
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackClientError.invalidResponse
        }

        if httpResponse.statusCode != 200 && httpResponse.statusCode != 202 {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw FeedbackClientError.unexpectedStatus(code: httpResponse.statusCode, message: message)
        }

        return try decoder.decode(FeedbackSubmissionResult.self, from: data)
    }

    public func uploadAttachment(
        data: Data,
        filename: String,
        mimeType: String,
        preferredKind: FeedbackAttachment.Kind? = nil
    ) async throws -> FeedbackAttachment {
        let endpointKind = preferredKind ?? (mimeType.hasPrefix("image/") ? .image : .r2)
        let endpoint = endpointKind == .image ? "/api/v1/uploads/images" : "/api/v1/uploads/r2"

        var request = URLRequest(url: configuration.baseURL.appending(path: endpoint))
        request.httpMethod = "POST"

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
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

        if httpResponse.statusCode != 200 {
            let message = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw FeedbackClientError.unexpectedStatus(code: httpResponse.statusCode, message: message)
        }

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
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
