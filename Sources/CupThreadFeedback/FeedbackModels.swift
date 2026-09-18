import Foundation

/// The platform a feedback submission or user attribute report comes from.
///
/// The backend distinguishes `ios` / `macos` / `android` / `universal`; the
/// value is stored with submissions and shown in the console.
public enum FeedbackPlatform: String, Codable, CaseIterable, Identifiable, Sendable {
    case ios
    case macos
    case android
    case universal

    public var id: String { rawValue }

    /// The platform value the SDK reports for the OS it is running on.
    ///
    /// The backend distinguishes `ios` / `macos` / `android` / `universal`.
    /// visionOS and tvOS apps are iOS-family builds, so they report `.ios`
    /// — the value most app allow-lists already accept. Override with
    /// `FeedbackClientConfiguration(defaultPlatform:)` when needed.
    public static var current: FeedbackPlatform {
        #if os(macOS)
        return .macos
        #else
        return .ios
        #endif
    }
}

public extension FeedbackDraft {
    /// Returns a draft pre-filled with the host app's platform, version, and build
    /// number read from `Bundle.main`, so users never type them manually.
    ///
    /// Priority (!/!!/!!!) is intentionally absent: it is a developer-side triage
    /// attribute set in the CupThread console, not an end-user field.
    /// - Parameter platform: Platform recorded on the draft; defaults to the
    ///   OS the SDK is running on.
    /// - Returns: A draft with `platform`, `appVersion`, and `buildNumber` set.
    static func autofilled(platform: FeedbackPlatform = FeedbackPlatform.current) -> FeedbackDraft {
        let info = Bundle.main.infoDictionary ?? [:]
        return FeedbackDraft(
            platform: platform,
            appVersion: info["CFBundleShortVersionString"] as? String ?? "",
            buildNumber: info["CFBundleVersion"] as? String ?? ""
        )
    }
}

/// A file uploaded through
/// ``FeedbackClient/uploadAttachment(data:filename:mimeType:userToken:)`` or
/// ``FeedbackClient/uploadAttachment(fileURL:filename:mimeType:userToken:)``
/// and attached to a ``FeedbackDraft``.
public struct FeedbackAttachment: Codable, Equatable, Sendable, Identifiable {
    /// Which storage backend holds the file.
    public enum Kind: String, Codable, Sendable {
        /// General object storage, used for non-image attachments.
        case r2
        /// The image upload pipeline, used for `image/*` files.
        case image
    }

    /// The upload-session id binding this attachment to its uploaded bytes.
    /// Sent with feedback submission as `uploadIds`; `nil` only for legacy
    /// references created before the upload-session flow (those are ignored
    /// at submission time).
    public let uploadId: String?

    /// The storage backend the file lives in.
    public let kind: Kind
    /// Server-assigned identifier for the upload. For session uploads this
    /// equals ``uploadId``; kept for display fallbacks and legacy references.
    public let key: String
    /// URL where the file can be fetched.
    public let url: URL
    /// Original filename, when one was provided with the upload.
    public let filename: String?
    /// MIME type of the uploaded file, when known.
    public let mimeType: String?
    /// File size in bytes, when the server reported it.
    public let size: Int?

    /// Stable identity for `Identifiable`; equal to ``key``.
    public var id: String { key }

    /// Creates an attachment reference, typically from an upload response.
    /// - Parameters:
    ///   - kind: The storage backend holding the file.
    ///   - uploadId: Upload-session id binding the attachment to its bytes.
    ///   - key: Server-assigned storage key.
    ///   - url: URL where the file can be fetched.
    ///   - filename: Original filename, if any.
    ///   - mimeType: MIME type of the file, if known.
    ///   - size: File size in bytes, if known.
    public init(
        kind: Kind,
        uploadId: String? = nil,
        key: String,
        url: URL,
        filename: String? = nil,
        mimeType: String? = nil,
        size: Int? = nil
    ) {
        self.kind = kind
        self.uploadId = uploadId
        self.key = key
        self.url = url
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .image
        uploadId = try container.decodeIfPresent(String.self, forKey: .uploadId)
        key = try container.decode(String.self, forKey: .key)
        url = try container.decode(URL.self, forKey: .url)
        filename = try container.decodeIfPresent(String.self, forKey: .filename)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
    }
}

/// A feedback draft as typed by the end user, before submission.
///
/// Construct one directly, or start from ``FeedbackDraft/autofilled(platform:)``
/// which pre-fills the host app's version and build number:
///
/// ```swift
/// var draft = FeedbackDraft.autofilled()
/// draft.title = "Export to CSV"
/// draft.description = "I would love to export my reports."
/// draft.metadata["locale"] = Locale.current.identifier
/// ```
public struct FeedbackDraft: Codable, Equatable, Sendable {
    /// Short summary of the report, shown as its title everywhere.
    public var title: String
    /// Full description of the problem or suggestion.
    public var description: String
    /// Optional display name the user typed; empty means anonymous.
    public var reporterName: String
    /// Optional reply-to email address; empty means none.
    public var reporterEmail: String
    /// Platform reported with the submission.
    public var platform: FeedbackPlatform
    /// The host app's marketing version, e.g. `"2.1.0"`.
    public var appVersion: String
    /// The host app's build number, e.g. `"142"`.
    public var buildNumber: String
    /// Free-form key/value pairs merged into the submission for triage.
    ///
    /// Sanitized per the server's redaction contract before sending:
    /// credential-looking keys are replaced with `"[redacted]"`, values are
    /// truncated to 512 characters, and the payload is capped at 24 keys / 8 KB.
    /// The reserved keys `sdk`, `sdkVersion`, `platform`, and `submittedAt`
    /// are SDK-authored: draft entries with those names cannot replace the
    /// SDK's values on the wire, while every other custom key is preserved.
    public var metadata: [String: String]
    /// References returned by the ``FeedbackClient/uploadAttachment(data:filename:mimeType:userToken:)``
    /// and ``FeedbackClient/uploadAttachment(fileURL:filename:mimeType:userToken:)`` variants.
    /// Their `uploadId`s are sent with the submission.
    public var attachments: [FeedbackAttachment]

    /// Creates a draft. All fields except `platform` default to empty.
    /// - Parameters:
    ///   - title: Short summary of the feedback.
    ///   - description: Detailed explanation or steps to reproduce.
    ///   - reporterName: Optional name of the user.
    ///   - reporterEmail: Optional contact email of the user.
    ///   - platform: Platform reported with the submission.
    ///   - appVersion: The host app's marketing version.
    ///   - buildNumber: The host app's build number.
    ///   - metadata: Free-form key/value pairs merged into the submission for triage.
    ///   - attachments: Uploaded attachment references.
    public init(
        title: String = "",
        description: String = "",
        reporterName: String = "",
        reporterEmail: String = "",
        platform: FeedbackPlatform,
        appVersion: String = "",
        buildNumber: String = "",
        metadata: [String: String] = [:],
        attachments: [FeedbackAttachment] = []
    ) {
        self.title = title
        self.description = description
        self.reporterName = reporterName
        self.reporterEmail = reporterEmail
        self.platform = platform
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.metadata = metadata
        self.attachments = attachments
    }

    /// Whether the draft holds anything the user typed or attached.
    ///
    /// Autofilled environment fields (`platform`, `appVersion`, `buildNumber`)
    /// and `metadata` do not count — only title, description, contact fields,
    /// and attachments are user content worth protecting from accidental
    /// dismissal.
    public var hasContent: Bool {
        let whitespace = CharacterSet.whitespacesAndNewlines
        if !title.trimmingCharacters(in: whitespace).isEmpty { return true }
        if !description.trimmingCharacters(in: whitespace).isEmpty { return true }
        if !reporterName.trimmingCharacters(in: whitespace).isEmpty { return true }
        if !reporterEmail.trimmingCharacters(in: whitespace).isEmpty { return true }
        return !attachments.isEmpty
    }
}

/// The server's receipt for a submitted feedback draft.
///
/// Returned by ``FeedbackClient/submit(_:userToken:)`` and also delivered to
/// ``FeedbackComposerView`` host apps through its `onSubmit` callback.
///
/// Decoding is lenient: the documented response carries `id`, `title`,
/// `status`, and `createdAt`, while older deployments answered with
/// `submissionId`, `forwardedToGithub`, and warning fields. The SDK accepts
/// both shapes.
public struct FeedbackSubmissionResult: Decodable, Equatable, Sendable {
    /// Server-assigned id for the submission.
    public let submissionId: String
    /// Whether the backend mirrored the submission to its GitHub tracker.
    public let forwardedToGithub: Bool
    /// GitHub discussion id, when the submission was mirrored.
    public let githubDiscussionId: String?
    /// GitHub discussion URL, when the submission was mirrored.
    public let githubDiscussionUrl: URL?
    /// Non-fatal warning from the server, shown to the user when present.
    public let warning: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        submissionId = try container.decodeIfPresent(String.self, forKey: .submissionId)
            ?? container.decodeIfPresent(String.self, forKey: .id)
            ?? ""
        forwardedToGithub = try container.decodeIfPresent(Bool.self, forKey: .forwardedToGithub) ?? false
        githubDiscussionId = try container.decodeIfPresent(String.self, forKey: .githubDiscussionId)
        githubDiscussionUrl = try container.decodeIfPresent(URL.self, forKey: .githubDiscussionUrl)
        warning = try container.decodeIfPresent(String.self, forKey: .warning)
    }

    private enum CodingKeys: String, CodingKey {
        case submissionId, id, forwardedToGithub
        case githubDiscussionId, githubDiscussionUrl, warning
    }
}
