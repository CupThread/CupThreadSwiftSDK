import Foundation
import Testing
@testable import CupThreadFeedback

/// Typed error & attachment-validation copy (issue #266): the
/// `errorDescription` implementations of `FeedbackClientError` and
/// `AttachmentValidationError` must resolve through the string tables
/// instead of embedding hardcoded English, and the new
/// `cupthread.error.*` / `cupthread.attachment.*` keys must ship in every
/// locale.
@Suite("Error description localization")
struct ErrorDescriptionLocalizationTests {
    private func loadStrings(for language: String) throws -> [String: String] {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: BundleToken.self)
        #endif

        let stringsURL = try #require(
            bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language),
            "Missing Localizable.strings for \(language)"
        )
        let data = try Data(contentsOf: stringsURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let dict = try #require(plist as? [String: String], "Failed to parse strings plist for \(language)")
        return dict
    }

    /// Keys introduced by issue #266 for the typed error cases that
    /// previously shipped hardcoded English in `errorDescription`.
    /// `.rateLimited` intentionally reuses `cupthread.error.http_rate_limited`
    /// so it reads identically to `.unexpectedStatus(code: 429)`.
    private static let errorDescriptionKeys = [
        "cupthread.error.invalid_response",
        "cupthread.error.unreadable_upload_response",
        "cupthread.error.auth_required",
        "cupthread.error.scan_rejected",
        "cupthread.error.unsupported_media",
        "cupthread.error.payload_too_large",
        "cupthread.error.uploader_identity_required",
        "cupthread.error.uploader_mismatch",
        "cupthread.error.quota_exceeded",
        "cupthread.error.subscription_inactive",
        "cupthread.error.profile_not_found",
        "cupthread.error.comments_unavailable",
        "cupthread.error.email_not_verified",
        "cupthread.attachment.oversized",
        "cupthread.attachment.unprocessable",
        "cupthread.attachment.unsupported_type"
    ]

    /// The English literals that used to be hardcoded in `errorDescription`
    /// before issue #266 — translated copy must never round-trip to one.
    private static let preI18NEnglishLiterals = [
        "The feedback server returned an invalid response.",
        "The feedback server returned an unreadable upload response.",
        "This action is only available to signed-in users.",
        "The referenced attachment could not be uploaded due to content inspection rejection.",
        "That image type isn't supported. Please attach a PNG, JPEG, WebP, or GIF.",
        "That file is too large to upload.",
        "Uploads require an end-user identity. Pass a userToken (see UserTokenStore) when uploading attachments.",
        "This attachment was uploaded with a different identity. Please remove and re-attach it, then try again.",
        "This app has reached its submission limit for this month. Please try again later.",
        "Submissions are unavailable for this app right now. Please try again later.",
        "This user profile is no longer available.",
        "Comments are not available for this feature request.",
        "Please use your signed-in account email address to subscribe.",
        "The selected photo could not be processed for upload."
    ]

    /// Every typed `FeedbackClientError` description resolves through the
    /// catalog for the current process locale (issue #266). Compared against
    /// `CupThreadStrings.tr` output, so the assertion holds under any dev/CI
    /// locale.
    @Test func feedbackClientErrorDescriptionsResolveThroughCatalog() {
        #expect(
            FeedbackClientError.invalidResponse.errorDescription
                == CupThreadStrings.tr("cupthread.error.invalid_response")
        )
        #expect(
            FeedbackClientError.unreadableUploadResponse.errorDescription
                == CupThreadStrings.tr("cupthread.error.unreadable_upload_response")
        )
        #expect(
            FeedbackClientError.authenticationRequired.errorDescription
                == CupThreadStrings.tr("cupthread.error.auth_required")
        )
        #expect(
            FeedbackClientError.scanRejected(message: "raw detail").errorDescription
                == CupThreadStrings.tr("cupthread.error.scan_rejected")
        )
        #expect(
            FeedbackClientError.unsupportedMediaType(message: nil, requestId: nil).errorDescription
                == CupThreadStrings.tr("cupthread.error.unsupported_media")
        )
        #expect(
            FeedbackClientError.payloadTooLarge(message: nil, requestId: nil).errorDescription
                == CupThreadStrings.tr("cupthread.error.payload_too_large")
        )
        #expect(
            FeedbackClientError.uploaderIdentityRequired(message: nil, requestId: nil).errorDescription
                == CupThreadStrings.tr("cupthread.error.uploader_identity_required")
        )
        #expect(
            FeedbackClientError.uploaderMismatch(message: nil, requestId: nil).errorDescription
                == CupThreadStrings.tr("cupthread.error.uploader_mismatch")
        )
        #expect(
            FeedbackClientError.submissionQuotaExceeded(message: nil, requestId: nil).errorDescription
                == CupThreadStrings.tr("cupthread.error.quota_exceeded")
        )
        #expect(
            FeedbackClientError.subscriptionInactive(message: nil, requestId: nil).errorDescription
                == CupThreadStrings.tr("cupthread.error.subscription_inactive")
        )
        #expect(
            FeedbackClientError.userProfileNotFound(message: nil).errorDescription
                == CupThreadStrings.tr("cupthread.error.profile_not_found")
        )
        #expect(
            FeedbackClientError.commentsUnavailable(message: nil, requestId: nil).errorDescription
                == CupThreadStrings.tr("cupthread.error.comments_unavailable")
        )
        #expect(
            FeedbackClientError.emailNotVerified(message: nil, requestId: nil).errorDescription
                == CupThreadStrings.tr("cupthread.error.email_not_verified")
        )
    }

    /// Issue #266 acceptance: a typed `.rateLimited` and an
    /// `.unexpectedStatus(code: 429)` present the same localized copy, and
    /// the `(request id: …)` correlation suffix survives catalog routing.
    @Test func rateLimitCopyMatchesUnexpectedStatusAndKeepsRequestIdSuffix() {
        let typed = FeedbackClientError.rateLimited(message: nil, requestId: "req-266").errorDescription
        let status = FeedbackClientError.unexpectedStatus(
            code: 429, message: "<html>raw body</html>", requestId: "req-266"
        ).errorDescription
        #expect(typed == status, "Typed .rateLimited and .unexpectedStatus(429) must read identically")
        #expect(
            typed == CupThreadStrings.tr("cupthread.error.http_rate_limited") + " (request id: req-266)",
            "Unexpected typed rate-limit copy: \(typed ?? "nil")"
        )
    }

    /// `AttachmentValidationError` descriptions resolve through the catalog,
    /// keeping the two-value size interpolation and leaving no format
    /// specifier in the rendered copy (issue #266).
    @Test func attachmentValidationDescriptionsResolveThroughCatalog() throws {
        let size = ByteCountFormatter.string(fromByteCount: 1_572_864, countStyle: .file)
        let limit = ByteCountFormatter.string(fromByteCount: 20_000_000, countStyle: .file)
        let oversized = try #require(
            AttachmentValidationError.oversized(size: 1_572_864, limit: 20_000_000).errorDescription
        )
        #expect(
            oversized == CupThreadStrings.tr("cupthread.attachment.oversized", size, limit),
            "Unexpected oversized copy: \(oversized)"
        )
        #expect(oversized.contains(size), "Size argument missing: \(oversized)")
        #expect(oversized.contains(limit), "Limit argument missing: \(oversized)")
        #expect(!oversized.contains("%"), "Format specifier leaked into output: \(oversized)")

        #expect(
            AttachmentValidationError.unprocessableImage.errorDescription
                == CupThreadStrings.tr("cupthread.attachment.unprocessable")
        )
        #expect(
            AttachmentValidationError.unsupportedType.errorDescription
                == CupThreadStrings.tr("cupthread.attachment.unsupported_type")
        )
    }

    /// Issue #266 acceptance, catalog level: in the sampled non-English
    /// locales every new key is present, non-empty, translated (differs from
    /// the English catalog value), and matches none of the previously
    /// hardcoded English literals.
    @Test func errorCopyIsTranslatedInSampledLocales() throws {
        let enDict = try loadStrings(for: "en")
        for lang in ["de", "ja", "zh-Hans"] {
            let strings = try loadStrings(for: lang)
            for key in Self.errorDescriptionKeys {
                let value = try #require(strings[key], "\(lang) is missing \(key)")
                #expect(!value.isEmpty, "\(lang) has empty \(key)")
                let enValue = try #require(enDict[key], "en is missing \(key)")
                #expect(value != enValue, "\(lang) ships the English copy for \(key)")
                for literal in Self.preI18NEnglishLiterals {
                    #expect(
                        value != literal,
                        "\(lang) copy for \(key) collides with a pre-#266 English literal"
                    )
                }
            }
        }
    }
}
