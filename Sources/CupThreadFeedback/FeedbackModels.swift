import Foundation

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
    static func autofilled(platform: FeedbackPlatform = FeedbackPlatform.current) -> FeedbackDraft {
        let info = Bundle.main.infoDictionary ?? [:]
        return FeedbackDraft(
            platform: platform,
            appVersion: info["CFBundleShortVersionString"] as? String ?? "",
            buildNumber: info["CFBundleVersion"] as? String ?? ""
        )
    }
}

public struct FeedbackAttachment: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case r2
        case image
    }

    public let kind: Kind
    public let key: String
    public let url: URL
    public let filename: String?
    public let mimeType: String?
    public let size: Int?

    public var id: String { key }

    public init(
        kind: Kind,
        key: String,
        url: URL,
        filename: String? = nil,
        mimeType: String? = nil,
        size: Int? = nil
    ) {
        self.kind = kind
        self.key = key
        self.url = url
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
    }
}

public struct FeedbackDraft: Codable, Equatable, Sendable {
    public var title: String
    public var description: String
    public var reporterName: String
    public var reporterEmail: String
    public var platform: FeedbackPlatform
    public var appVersion: String
    public var buildNumber: String
    public var metadata: [String: String]
    public var attachments: [FeedbackAttachment]

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
}

public struct FeedbackSubmissionResult: Codable, Equatable, Sendable {
    public let submissionId: String
    public let forwardedToGithub: Bool
    public let githubDiscussionId: String?
    public let githubDiscussionUrl: URL?
    public let warning: String?
}
