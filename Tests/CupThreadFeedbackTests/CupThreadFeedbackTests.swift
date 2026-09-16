// swiftlint:disable file_length
// This suite is organized by type and intentionally exceeds the default
// file-length budget (see .swiftlint.yml).
import Foundation
import Testing
@testable import CupThreadFeedback

// Shared mock helpers (MockURLProtocol, makeClient, …) live in TestSupport.swift.

// MARK: - FeedbackPlatform

@Suite("FeedbackPlatform")
struct FeedbackPlatformTests {
    @Test func rawValues() {
        #expect(FeedbackPlatform.ios.rawValue == "ios")
        #expect(FeedbackPlatform.macos.rawValue == "macos")
        #expect(FeedbackPlatform.universal.rawValue == "universal")
    }

    @Test func currentMatchesHostPlatform() {
        #if os(macOS)
        #expect(FeedbackPlatform.current == .macos)
        #else
        // iOS-family builds (iOS, iPadOS, visionOS, tvOS) report ios.
        #expect(FeedbackPlatform.current == .ios)
        #endif
    }

    @Test func idEqualsRawValue() {
        for platform in FeedbackPlatform.allCases {
            #expect(platform.id == platform.rawValue)
        }
    }

    @Test func allCasesHasFourCases() {
        #expect(FeedbackPlatform.allCases.count == 4)
    }

    @Test func codableRoundTrip() throws {
        for platform in FeedbackPlatform.allCases {
            let data = try JSONEncoder().encode(platform)
            let decoded = try JSONDecoder().decode(FeedbackPlatform.self, from: data)
            #expect(decoded == platform)
        }
    }
}

// MARK: - FeedbackDraft autofill

@Suite("FeedbackDraftAutofill")
struct FeedbackDraftAutofillTests {
    @Test func autofilledUsesRequestedPlatform() {
        let draft = FeedbackDraft.autofilled(platform: .macos)
        #expect(draft.platform == .macos)
    }

    @Test func autofilledMirrorsBundleVersionInfo() {
        let info = Bundle.main.infoDictionary ?? [:]
        let draft = FeedbackDraft.autofilled(platform: .ios)
        #expect(draft.appVersion == (info["CFBundleShortVersionString"] as? String ?? ""))
        #expect(draft.buildNumber == (info["CFBundleVersion"] as? String ?? ""))
    }

    @Test func autofilledStartsEmptyForUserContent() {
        let draft = FeedbackDraft.autofilled(platform: .ios)
        #expect(draft.title.isEmpty)
        #expect(draft.description.isEmpty)
        #expect(draft.metadata.isEmpty)
        #expect(draft.attachments.isEmpty)
    }
}

// MARK: - FeedbackAttachment

@Suite("FeedbackAttachment")
struct FeedbackAttachmentTests {
    let sampleURL = URL(string: "https://example.com/file.png")!

    @Test func kindRawValues() {
        #expect(FeedbackAttachment.Kind.r2.rawValue == "r2")
        #expect(FeedbackAttachment.Kind.image.rawValue == "image")
    }

    @Test func idEqualsKey() {
        let attachment = FeedbackAttachment(kind: .image, key: "my-key", url: sampleURL)
        #expect(attachment.id == "my-key")
    }

    @Test func equalityWhenSameValues() {
        let a = FeedbackAttachment(kind: .image, key: "k1", url: sampleURL, filename: "f.png", mimeType: "image/png", size: 42)
        let b = FeedbackAttachment(kind: .image, key: "k1", url: sampleURL, filename: "f.png", mimeType: "image/png", size: 42)
        #expect(a == b)
    }

    @Test func inequalityWhenKeyDiffers() {
        let a = FeedbackAttachment(kind: .image, key: "k1", url: sampleURL)
        let b = FeedbackAttachment(kind: .image, key: "k2", url: sampleURL)
        #expect(a != b)
    }

    @Test func inequalityWhenKindDiffers() {
        let a = FeedbackAttachment(kind: .r2, key: "k", url: sampleURL)
        let b = FeedbackAttachment(kind: .image, key: "k", url: sampleURL)
        #expect(a != b)
    }

    @Test func optionalFieldsDefaultToNil() {
        let a = FeedbackAttachment(kind: .r2, key: "k", url: sampleURL)
        #expect(a.filename == nil)
        #expect(a.mimeType == nil)
        #expect(a.size == nil)
    }

    @Test func codableRoundTrip() throws {
        let original = FeedbackAttachment(
            kind: .image, key: "img-key", url: sampleURL,
            filename: "photo.png", mimeType: "image/png", size: 1024
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FeedbackAttachment.self, from: data)
        #expect(decoded == original)
    }
}

// MARK: - FeedbackDraft

@Suite("FeedbackDraft")
struct FeedbackDraftTests {
    @Test func defaultValuesForIosPlatform() {
        let draft = FeedbackDraft(platform: .ios)
        #expect(draft.title.isEmpty)
        #expect(draft.description.isEmpty)
        #expect(draft.reporterName.isEmpty)
        #expect(draft.reporterEmail.isEmpty)
        #expect(draft.platform == .ios)
        #expect(draft.appVersion.isEmpty)
        #expect(draft.buildNumber.isEmpty)
        #expect(draft.metadata.isEmpty)
        #expect(draft.attachments.isEmpty)
    }

    @Test func draftStoresProvidedPlatform() {
        let draft = FeedbackDraft(platform: .macos)
        #expect(draft.platform == .macos)
    }

    @Test func equalityWhenIdentical() {
        // title comes before platform in the init signature
        let a = FeedbackDraft(title: "Bug", description: "Details", platform: .ios)
        let b = FeedbackDraft(title: "Bug", description: "Details", platform: .ios)
        #expect(a == b)
    }

    @Test func inequalityWhenTitleDiffers() {
        let a = FeedbackDraft(title: "Bug A", platform: .ios)
        let b = FeedbackDraft(title: "Bug B", platform: .ios)
        #expect(a != b)
    }

    @Test func inequalityWhenPlatformDiffers() {
        let a = FeedbackDraft(platform: .ios)
        let b = FeedbackDraft(platform: .macos)
        #expect(a != b)
    }

    @Test func customMetadataIsStored() {
        let draft = FeedbackDraft(platform: .ios, metadata: ["device": "iPhone 15", "version": "17.2"])
        #expect(draft.metadata["device"] == "iPhone 15")
        #expect(draft.metadata["version"] == "17.2")
    }

    @Test func customAttachmentsAreStored() {
        let url = URL(string: "https://example.com/img.png")!
        let attachment = FeedbackAttachment(kind: .image, key: "k1", url: url)
        let draft = FeedbackDraft(platform: .ios, attachments: [attachment])
        #expect(draft.attachments.count == 1)
        #expect(draft.attachments[0] == attachment)
    }
}

// MARK: - FeedbackSubmissionResult

@Suite("FeedbackSubmissionResult")
struct FeedbackSubmissionResultTests {
    @Test func decodesWithAllFields() throws {
        let json = Data("""
        {
            "submissionId": "sub-123",
            "forwardedToGithub": true,
            "githubDiscussionId": "D_abc",
            "githubDiscussionUrl": "https://github.com/owner/repo/discussions/42",
            "warning": null
        }
        """.utf8)

        let result = try JSONDecoder().decode(FeedbackSubmissionResult.self, from: json)
        #expect(result.submissionId == "sub-123")
        #expect(result.forwardedToGithub == true)
        #expect(result.githubDiscussionId == "D_abc")
        #expect(result.githubDiscussionUrl == URL(string: "https://github.com/owner/repo/discussions/42"))
        #expect(result.warning == nil)
    }

    @Test func decodesWithRequiredFieldsOnly() throws {
        let json = Data("""
        {
            "submissionId": "sub-456",
            "forwardedToGithub": false
        }
        """.utf8)

        let result = try JSONDecoder().decode(FeedbackSubmissionResult.self, from: json)
        #expect(result.submissionId == "sub-456")
        #expect(result.forwardedToGithub == false)
        #expect(result.githubDiscussionId == nil)
        #expect(result.githubDiscussionUrl == nil)
        #expect(result.warning == nil)
    }

    @Test func decodesWarningField() throws {
        let json = Data("""
        {
            "submissionId": "sub-789",
            "forwardedToGithub": false,
            "warning": "Submission stored but forwarding failed."
        }
        """.utf8)

        let result = try JSONDecoder().decode(FeedbackSubmissionResult.self, from: json)
        #expect(result.warning == "Submission stored but forwarding failed.")
    }

    @Test func equatableWhenSameValues() throws {
        let json = Data("""
        {"submissionId":"s","forwardedToGithub":true}
        """.utf8)
        let a = try JSONDecoder().decode(FeedbackSubmissionResult.self, from: json)
        let b = try JSONDecoder().decode(FeedbackSubmissionResult.self, from: json)
        #expect(a == b)
    }
}

// MARK: - FeedbackClientConfiguration

@Suite("FeedbackClientConfiguration")
struct FeedbackClientConfigurationTests {
    @Test func storesAllProvidedValues() {
        let url = URL(string: "https://api.example.com")!
        let config = FeedbackClientConfiguration(baseURL: url, appKey: "app_mykey12345", defaultPlatform: .macos)
        #expect(config.baseURL == url)
        #expect(config.appKey == "app_mykey12345")
        #expect(config.defaultPlatform == .macos)
    }

    @Test func equalityWhenSameValues() {
        let url = URL(string: "https://api.example.com")!
        let a = FeedbackClientConfiguration(baseURL: url, appKey: "key", defaultPlatform: .ios)
        let b = FeedbackClientConfiguration(baseURL: url, appKey: "key", defaultPlatform: .ios)
        #expect(a == b)
    }

    @Test func inequalityWhenAppKeyDiffers() {
        let url = URL(string: "https://api.example.com")!
        let a = FeedbackClientConfiguration(baseURL: url, appKey: "key1", defaultPlatform: .ios)
        let b = FeedbackClientConfiguration(baseURL: url, appKey: "key2", defaultPlatform: .ios)
        #expect(a != b)
    }

    @Test func inequalityWhenPlatformDiffers() {
        let url = URL(string: "https://api.example.com")!
        let a = FeedbackClientConfiguration(baseURL: url, appKey: "key", defaultPlatform: .ios)
        let b = FeedbackClientConfiguration(baseURL: url, appKey: "key", defaultPlatform: .macos)
        #expect(a != b)
    }

    @Test func storesSigningSecretWhenProvided() {
        let url = URL(string: "https://api.example.com")!
        let config = FeedbackClientConfiguration(
            baseURL: url,
            appKey: "app_mykey12345",
            signingSecret: "sec_test_secret"
        )
        #expect(config.signingSecret == "sec_test_secret")
    }

    @Test func defaultSigningSecretIsNil() {
        let url = URL(string: "https://api.example.com")!
        let config = FeedbackClientConfiguration(baseURL: url, appKey: "app_mykey12345")
        #expect(config.signingSecret == nil)
    }

    @Test func inequalityWhenSigningSecretDiffers() {
        let url = URL(string: "https://api.example.com")!
        let a = FeedbackClientConfiguration(baseURL: url, appKey: "key", signingSecret: "secret1")
        let b = FeedbackClientConfiguration(baseURL: url, appKey: "key", signingSecret: "secret2")
        let withoutSecret = FeedbackClientConfiguration(baseURL: url, appKey: "key", signingSecret: nil)
        #expect(a != b)
        #expect(a != withoutSecret)
    }
}

// MARK: - FeedbackClientError

@Suite("FeedbackClientError")
struct FeedbackClientErrorTests {
    @Test func invalidResponseHasNonEmptyDescription() {
        let error = FeedbackClientError.invalidResponse
        let desc = error.errorDescription
        #expect(desc != nil)
        #expect(!(desc?.isEmpty ?? true))
    }

    @Test func unreadableUploadResponseHasNonEmptyDescription() {
        let error = FeedbackClientError.unreadableUploadResponse
        let desc = error.errorDescription
        #expect(desc != nil)
        #expect(!(desc?.isEmpty ?? true))
    }

    @Test func unexpectedStatusDescriptionContainsCode() throws {
        let error = FeedbackClientError.unexpectedStatus(code: 503, message: "Service Unavailable", requestId: nil)
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("503"))
    }

    @Test func unexpectedStatusDescriptionContainsMessage() throws {
        let error = FeedbackClientError.unexpectedStatus(code: 503, message: "Service Unavailable", requestId: nil)
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("Service Unavailable"))
    }

    @Test func unexpectedStatusDescriptionContainsRequestIDWhenPresent() throws {
        let error = FeedbackClientError.unexpectedStatus(
            code: 503, message: "Service Unavailable", requestId: "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
        )
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("request id: 0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"))
    }

    @Test func unexpectedStatusDescriptionOmitsRequestIDWhenAbsent() throws {
        let error = FeedbackClientError.unexpectedStatus(code: 503, message: "Service Unavailable", requestId: nil)
        let desc = try #require(error.errorDescription)
        #expect(!desc.contains("request id"))
    }

    @Test func unexpectedStatusWith400ContainsCode() throws {
        let error = FeedbackClientError.unexpectedStatus(code: 400, message: "Validation failed", requestId: nil)
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("400"))
    }

    @Test func scanRejectedHasLocalizedDescriptionWithoutMessage() {
        let error = FeedbackClientError.scanRejected(message: "")
        let desc = error.errorDescription
        #expect(desc == "The referenced attachment could not be uploaded due to content inspection rejection.")
    }

    @Test func scanRejectedHasLocalizedDescriptionWithMessage() throws {
        let reason = "Upload object upl_123 was rejected by content scan: malware detected"
        let error = FeedbackClientError.scanRejected(message: reason)
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("The referenced attachment could not be uploaded due to content inspection rejection"))
        #expect(desc.contains(reason))
    }

    @Test func scanRejectedEquatable() {
        let error1 = FeedbackClientError.scanRejected(message: "abc")
        let error2 = FeedbackClientError.scanRejected(message: "abc")
        let error3 = FeedbackClientError.scanRejected(message: "xyz")
        #expect(error1 == error2)
        #expect(error1 != error3)
    }

    @Test func rateLimitedHasFriendlyDescription() {
        let error = FeedbackClientError.rateLimited(message: "Too many votes. Please try again shortly.")
        let desc = error.errorDescription
        #expect(desc == "You're doing that too often. Please try again in a minute.")
    }

    @Test func unsupportedMediaTypeHasFriendlyDescription() {
        let error = FeedbackClientError.unsupportedMediaType(message: "image/svg+xml is not accepted")
        let desc = error.errorDescription
        #expect(desc?.contains("PNG, JPEG, WebP, or GIF") == true)
    }

    @Test func payloadTooLargeHasFriendlyDescription() {
        let error = FeedbackClientError.payloadTooLarge(message: nil)
        let desc = error.errorDescription
        #expect(desc?.contains("too large") == true)
    }

    @Test func uploaderMismatchHasReattachGuidance() {
        let error = FeedbackClientError.uploaderMismatch(message: "Upload session was created by a different uploader")
        let desc = error.errorDescription
        #expect(desc?.contains("different identity") == true)
        #expect(desc?.contains("re-attach") == true)
    }

    @Test func uploaderIdentityRequiredNamesUserToken() {
        let error = FeedbackClientError.uploaderIdentityRequired(message: nil)
        let desc = error.errorDescription
        #expect(desc?.contains("userToken") == true)
    }
}

// MARK: - FeedbackClient (serialized — tests share a static URLProtocol handler)

/// All FeedbackClient network tests run serially to prevent races on MockURLProtocol.requestHandler.
@Suite("FeedbackClient", .serialized)
// swiftlint:disable:next type_body_length
struct FeedbackClientTests {

// MARK: Submit

// swiftlint:disable:next type_body_length
struct FeedbackClientSubmitTests {
    let baseURL = URL(string: "https://test.example.com")!
    let appKey = "app_testsubmitkey1"

    @Test func sendsPostToFeedbackEndpoint() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.requestHandler = { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["submissionId": "s-1", "forwardedToGithub": true]))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        _ = try await client.submit(FeedbackDraft(title: "Test", description: "Testing submit", platform: .ios))

        let req = try #require(capture.value)
        #expect(req.url?.path == "/api/v1/feedback")
        #expect(req.httpMethod == "POST")
    }

    @Test func setsContentTypeJSON() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.requestHandler = { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["submissionId": "s-1", "forwardedToGithub": true]))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        _ = try await client.submit(FeedbackDraft(title: "T", description: "Desc ok", platform: .ios))

        let req = try #require(capture.value)
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func bodyContainsAppKey() async throws {
        // Capture raw Data (Sendable), decode in test body
        let capture = CaptureBox<Data>()
        MockURLProtocol.requestHandler = { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(), try encodeJSON(["submissionId": "s-1", "forwardedToGithub": true]))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        _ = try await client.submit(FeedbackDraft(title: "Title", description: "Description ok", platform: .ios))

        let rawData = try #require(capture.value)
        let json = try #require(parseJSONDict(rawData))
        #expect(json["appKey"] as? String == appKey)
    }

    @Test func bodyTrimsTitleAndDescription() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.requestHandler = { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(), try encodeJSON(["submissionId": "s-1", "forwardedToGithub": true]))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        _ = try await client.submit(FeedbackDraft(title: "  My Title  ", description: "  Some description  ", platform: .ios))

        let rawData = try #require(capture.value)
        let json = try #require(parseJSONDict(rawData))
        #expect(json["title"] as? String == "My Title")
        #expect(json["description"] as? String == "Some description")
    }

    @Test func bodyIncludesSdkInMetadata() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.requestHandler = { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(), try encodeJSON(["submissionId": "s-1", "forwardedToGithub": true]))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        _ = try await client.submit(FeedbackDraft(title: "T", description: "Desc", platform: .ios))

        let rawData = try #require(capture.value)
        let json = try #require(parseJSONDict(rawData))
        let metadata = json["metadata"] as? [String: String]
        #expect(metadata?["sdk"] == "cupthread-apple")
    }

    @Test func reporterNameIsOmittedWhenWhitespaceOnly() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.requestHandler = { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(), try encodeJSON(["submissionId": "s-1", "forwardedToGithub": true]))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        let draft = FeedbackDraft(title: "T", description: "Desc ok", reporterName: "   ", platform: .ios)
        _ = try await client.submit(draft)

        let rawData = try #require(capture.value)
        let json = try #require(parseJSONDict(rawData))
        // nil optional → key absent from JSON (JSONEncoder skips nil optionals by default)
        let nameValue = json["reporterName"]
        #expect(nameValue == nil || nameValue is NSNull)
    }

    @Test func reporterEmailIsIncludedWhenProvided() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.requestHandler = { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(), try encodeJSON(["submissionId": "s-1", "forwardedToGithub": true]))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        let draft = FeedbackDraft(title: "T", description: "Desc ok", reporterEmail: "user@example.com", platform: .ios)
        _ = try await client.submit(draft)

        let rawData = try #require(capture.value)
        let json = try #require(parseJSONDict(rawData))
        #expect(json["reporterEmail"] as? String == "user@example.com")
    }

    @Test func successfulResponseDecodesResult() async throws {
        MockURLProtocol.requestHandler = { _ in
            let body: [String: Any] = [
                "submissionId": "sub-xyz",
                "forwardedToGithub": true,
                "githubDiscussionId": "D_abc",
                "githubDiscussionUrl": "https://github.com/o/r/discussions/1"
            ]
            return (makeHTTPResponse(status: 200), try encodeJSON(body))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        let result = try await client.submit(FeedbackDraft(title: "T", description: "Desc ok", platform: .ios))
        #expect(result.submissionId == "sub-xyz")
        #expect(result.forwardedToGithub == true)
        #expect(result.githubDiscussionId == "D_abc")
    }

    @Test func status201AlsoDecodes() async throws {
        MockURLProtocol.requestHandler = { _ in
            let body: [String: Any] = [
                "submissionId": "sub-201",
                "forwardedToGithub": false
            ]
            return (makeHTTPResponse(status: 201), try encodeJSON(body))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        let result = try await client.submit(FeedbackDraft(title: "T", description: "Desc ok", platform: .ios))
        #expect(result.submissionId == "sub-201")
        #expect(result.forwardedToGithub == false)
        #expect(result.githubDiscussionId == nil)
        #expect(result.githubDiscussionUrl == nil)
        #expect(result.warning == nil)
    }

    @Test func status202AlsoDecodes() async throws {
        MockURLProtocol.requestHandler = { _ in
            let body: [String: Any] = [
                "submissionId": "sub-202",
                "forwardedToGithub": false,
                "warning": "Stored but not forwarded yet"
            ]
            return (makeHTTPResponse(status: 202), try encodeJSON(body))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        let result = try await client.submit(FeedbackDraft(title: "T", description: "Desc ok", platform: .ios))
        #expect(result.submissionId == "sub-202")
        #expect(result.forwardedToGithub == false)
        #expect(result.warning == "Stored but not forwarded yet")
    }

    @Test func unsupportedStatusThrowsUnexpectedStatus() async throws {
        MockURLProtocol.requestHandler = { _ in
            return (makeHTTPResponse(status: 204), try encodeJSON(["error": "No content"]))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        do {
            _ = try await client.submit(FeedbackDraft(title: "T", description: "Desc ok", platform: .ios))
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            if case .unexpectedStatus(let code, _, _) = error {
                #expect(code == 204)
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    @Test func errorStatusThrowsUnexpectedStatus() async throws {
        MockURLProtocol.requestHandler = { _ in
            return (makeHTTPResponse(status: 400), try encodeJSON(["error": "Validation failed"]))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        do {
            _ = try await client.submit(FeedbackDraft(title: "T", description: "Desc ok", platform: .ios))
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            if case .unexpectedStatus(let code, _, _) = error {
                #expect(code == 400)
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    @Test func submitThrowsScanRejectedWhenServerReturns422WithScanRejectedCode() async throws {
        let errorPayload: [String: Any] = [
            "error": "Upload object upl_scan_123 was rejected by content scan: malware signature detected",
            "code": "scan_rejected"
        ]
        MockURLProtocol.requestHandler = { _ in
            (makeHTTPResponse(status: 422), try encodeJSON(errorPayload))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        let draft = FeedbackDraft(
            title: "Bug report with attachment",
            description: "Here is the attachment that got rejected",
            platform: .ios,
            attachments: [
                FeedbackAttachment(
                    kind: .image,
                    key: "upl_scan_123",
                    url: URL(string: "https://example.com/upl_scan_123")!
                )
            ]
        )

        do {
            _ = try await client.submit(draft)
            Issue.record("Expected scanRejected error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .scanRejected(let message) = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(message.contains("upl_scan_123"))
            #expect(message.contains("malware signature detected"))
            let desc = try #require(error.errorDescription)
            #expect(desc.contains("The referenced attachment could not be uploaded due to content inspection rejection"))
            #expect(desc.contains("malware signature detected"))
        }
    }

    @Test func submitThrowsUnexpectedStatusWhen422HasNonScanRejectedCode() async throws {
        MockURLProtocol.requestHandler = { _ in
            (makeHTTPResponse(status: 422), try encodeJSON(["error": "Invalid format", "code": "unprocessable_data"]))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        do {
            _ = try await client.submit(FeedbackDraft(title: "T", description: "Desc ok", platform: .ios))
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            if case .unexpectedStatus(let code, let message, _) = error {
                #expect(code == 422)
                #expect(message.contains("Invalid format"))
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    @Test func submitThrowsUnexpectedStatusWhen422BodyIsNotJSON() async throws {
        MockURLProtocol.requestHandler = { _ in
            (makeHTTPResponse(status: 422), Data("Unprocessable Entity".utf8))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        do {
            _ = try await client.submit(FeedbackDraft(title: "T", description: "Desc ok", platform: .ios))
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            if case .unexpectedStatus(let code, let message, _) = error {
                #expect(code == 422)
                #expect(message == "Unprocessable Entity")
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    @Test func sendsXRequestIDHeaderAndReturnsItOnErrors() async throws {
        let capture = CaptureBox<String?>()
        MockURLProtocol.requestHandler = { request in
            capture.value = request.value(forHTTPHeaderField: "X-Request-Id")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["X-Request-Id": "server-generated-id-42", "Content-Type": "application/json"]
            )!
            return (response, try encodeJSON(["error": "Boom"]))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        do {
            _ = try await client.submit(FeedbackDraft(title: "T", description: "Desc ok", platform: .ios))
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            if case .unexpectedStatus(_, _, let requestId) = error {
                #expect(requestId == "server-generated-id-42")
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        }
        #expect(capture.value != nil)
        #expect(capture.value??.count == 36) // generated UUID
    }

    @Test func configurationRequestIDOverridesGeneratedUUID() async throws {
        let capture = CaptureBox<String?>()
        MockURLProtocol.requestHandler = { request in
            capture.value = request.value(forHTTPHeaderField: "X-Request-Id")
            return (makeHTTPResponse(), try encodeJSON(["submissionId": "s-1"]))
        }

        let config = FeedbackClientConfiguration(
            baseURL: baseURL,
            appKey: appKey,
            requestID: "stable-run-identifier-1"
        )
        let client = FeedbackClient(configuration: config, session: makeMockSession())
        _ = try await client.submit(FeedbackDraft(title: "T", description: "Desc ok", platform: .ios))

        #expect(capture.value == "stable-run-identifier-1")
    }

    @Test func attachmentsSentAsUploadIDs() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.requestHandler = { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(), try encodeJSON(["submissionId": "s-1"]))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        var draft = FeedbackDraft(title: "T", description: "Desc ok", platform: .ios)
        draft.attachments = [
            FeedbackAttachment(kind: .image, uploadId: "upl-1", key: "upl-1", url: URL(string: "https://example.com/1")!),
            FeedbackAttachment(kind: .r2, uploadId: "upl-2", key: "upl-2", url: URL(string: "https://example.com/2")!),
            // Legacy references without an uploadId are not submitted.
            FeedbackAttachment(kind: .image, key: "legacy-key", url: URL(string: "https://example.com/3")!)
        ]
        _ = try await client.submit(draft, userToken: "tok")

        let rawData = try #require(capture.value)
        let json = try #require(parseJSONDict(rawData))
        let uploadIds = try #require(json["uploadIds"] as? [String])
        #expect(uploadIds == ["upl-1", "upl-2"])
        #expect(json["attachments"] == nil)
    }

    @Test func omitsUploadIDsWhenNoAttachments() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.requestHandler = { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(), try encodeJSON(["submissionId": "s-1"]))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        _ = try await client.submit(FeedbackDraft(title: "T", description: "Desc ok", platform: .ios))

        let rawData = try #require(capture.value)
        let json = try #require(parseJSONDict(rawData))
        #expect(json["uploadIds"] == nil)
    }

    @Test func submitWithAttachmentsFallsBackToSharedStoreIdentity() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.requestHandler = { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["submissionId": "s-1"]))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        var draft = FeedbackDraft(title: "T", description: "Desc ok", platform: .ios)
        draft.attachments = [
            FeedbackAttachment(kind: .image, uploadId: "upl-1", key: "upl-1", url: URL(string: "https://example.com/1")!)
        ]
        _ = try await client.submit(draft, userToken: nil)

        let req = try #require(capture.value)
        let token = try #require(req.value(forHTTPHeaderField: "X-User-Token"))
        #expect(!token.isEmpty)
        #expect(UUID(uuidString: token) != nil)
        #expect(token == UserTokenStore.shared.token)
    }

    @Test func submitWithExplicitTokenSendsThatToken() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.requestHandler = { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["submissionId": "s-1"]))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        var draft = FeedbackDraft(title: "T", description: "Desc ok", platform: .ios)
        draft.attachments = [
            FeedbackAttachment(kind: .image, uploadId: "upl-1", key: "upl-1", url: URL(string: "https://example.com/1")!)
        ]
        _ = try await client.submit(draft, userToken: "tok-explicit")

        let req = try #require(capture.value)
        #expect(req.value(forHTTPHeaderField: "X-User-Token") == "tok-explicit")
    }

    @Test func submitWithoutAttachmentsOmitsTokenWhenNil() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.requestHandler = { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["submissionId": "s-1"]))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        let draft = FeedbackDraft(title: "T", description: "Desc ok", platform: .ios)
        _ = try await client.submit(draft, userToken: nil)

        let req = try #require(capture.value)
        #expect(req.value(forHTTPHeaderField: "X-User-Token") == nil)
    }

    @Test func decodesDocumentedIDOnlyResponseShape() async throws {
        MockURLProtocol.requestHandler = { _ in
            return (makeHTTPResponse(), try encodeJSON([
                "id": "abc-123", "title": "T", "status": "queued", "createdAt": "2026-09-13T00:00:00Z"
            ]))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        let result = try await client.submit(FeedbackDraft(title: "T", description: "Desc ok", platform: .ios))
        #expect(result.submissionId == "abc-123")
        #expect(result.forwardedToGithub == false)
        #expect(result.warning == nil)
    }

    @Test func sendsPlatformInBody() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.requestHandler = { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(), try encodeJSON(["submissionId": "s-1", "forwardedToGithub": true]))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        let draft = FeedbackDraft(title: "T", description: "Desc ok", platform: .macos)
        _ = try await client.submit(draft)

        let rawData = try #require(capture.value)
        let json = try #require(parseJSONDict(rawData))
        #expect(json["platform"] as? String == "macos")
        #expect(json["severity"] == nil)
    }

    @Test func reservedMetadataKeysSurviveLargeHostMetadataPayloads() async throws {
        let capture = CaptureBox<Data>()
        MockURLProtocol.requestHandler = { request in
            capture.value = bodyData(from: request)
            return (makeHTTPResponse(), try encodeJSON(["submissionId": "s-1", "forwardedToGithub": true]))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        var hostMetadata: [String: String] = [:]
        for index in 0..<30 {
            hostMetadata[String(format: "hostKey%02d", index)] = "value\(index)"
        }
        let draft = FeedbackDraft(
            title: "Large Metadata Test",
            description: "Testing reserved metadata survival",
            platform: .ios,
            metadata: hostMetadata
        )
        _ = try await client.submit(draft)

        let rawData = try #require(capture.value)
        let json = try #require(parseJSONDict(rawData))
        let metadata = try #require(json["metadata"] as? [String: String])

        #expect(metadata.count <= 24)
        #expect(metadata["sdk"] == "cupthread-apple")
        #expect(metadata["platform"] == "ios")
        #expect(metadata["submittedAt"] != nil)
        #expect(metadata["hostKey00"] == "value0")
    }

} // end FeedbackClientSubmitTests

// MARK: Upload (upload-session flow)

struct FeedbackClientUploadTests {
    let baseURL = URL(string: "https://test.example.com")!
    let appKey = "app_testuploadkey1"
    let sessionJSON: [String: Any] = [
        "session": [
            "sessionId": "sess-1",
            "sessionToken": "stok-abc",
            "expiresAt": "2026-09-13T12:00:00Z",
            "maxFileSizeBytes": 20_000_000,
            "maxFiles": 8
        ],
        "files": [[
            "clientFileId": "file-1",
            "uploadId": "upl-1",
            "uploadUrl": "https://test.example.com/api/v1/uploads/upl-1",
            "maxSizeBytes": 20_000_000
        ]]
    ]
    let uploadedJSON: [String: Any] = [
        "uploadId": "upl-1",
        "clientFileId": "file-1",
        "filename": "f.txt",
        "contentType": "text/plain",
        "sizeBytes": 4,
        "sha256": "abc",
        "stored": true,
        "downloadUrl": "https://example.com/f.txt"
    ]

    /// Handles the full session flow: POST /uploads/sessions then PUT /uploads/{id}.
    /// Appends every request to `requests` in call order.
    private func makeSessionFlowHandler(
        requests: CaptureBox<[URLRequest]>,
        putBody: CaptureBox<Data>? = nil,
        sessionStatus: Int = 201,
        putStatus: Int = 200
    ) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            requests.value = (requests.value ?? []) + [request]
            if request.httpMethod == "POST" {
                return (makeHTTPResponse(status: sessionStatus), try encodeJSON(self.sessionJSON))
            }
            putBody?.value = bodyData(from: request)
            return (makeHTTPResponse(status: putStatus), try encodeJSON(self.uploadedJSON))
        }
    }

    @Test func convenienceUploadCreatesSessionThenStreamsBytes() async throws {
        let requests = CaptureBox<[URLRequest]>()
        let putBody = CaptureBox<Data>()
        MockURLProtocol.requestHandler = makeSessionFlowHandler(requests: requests, putBody: putBody)

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        let attachment = try await client.uploadAttachment(
            data: Data("test".utf8), filename: "f.txt", mimeType: "text/plain", userToken: "tok-1"
        )

        let captured = try #require(requests.value)
        #expect(captured.count == 2)

        let sessionRequest = captured[0]
        #expect(sessionRequest.url?.path == "/api/v1/uploads/sessions")
        #expect(sessionRequest.httpMethod == "POST")
        #expect(sessionRequest.value(forHTTPHeaderField: "X-User-Token") == "tok-1")
        let sessionBodyData = try #require(bodyData(from: sessionRequest))
        let sessionBody = try #require(parseJSONDict(sessionBodyData))
        #expect(sessionBody["appKey"] as? String == appKey)
        let files = try #require(sessionBody["files"] as? [[String: Any]])
        #expect(files.first?["contentType"] as? String == "text/plain")
        #expect(files.first?["sizeBytes"] as? Int == 4)

        let putRequest = captured[1]
        #expect(putRequest.url?.path == "/api/v1/uploads/upl-1")
        #expect(putRequest.httpMethod == "PUT")
        #expect(putRequest.value(forHTTPHeaderField: "Authorization") == "Bearer stok-abc")
        #expect(putRequest.value(forHTTPHeaderField: "Content-Type") == "text/plain")
        #expect(putBody.value == Data("test".utf8))

        #expect(attachment.uploadId == "upl-1")
        #expect(attachment.key == "upl-1")
        #expect(attachment.size == 4)
        #expect(attachment.url == URL(string: "https://example.com/f.txt"))
    }

    @Test func sessionCreateWithoutTokenFallsBackToSharedStore() async throws {
        let requests = CaptureBox<[URLRequest]>()
        MockURLProtocol.requestHandler = makeSessionFlowHandler(requests: requests)

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        _ = try await client.uploadAttachment(
            data: Data("test".utf8), filename: "f.txt", mimeType: "text/plain", userToken: nil
        )

        let sessionRequest = try #require(requests.value?.first)
        let token = try #require(sessionRequest.value(forHTTPHeaderField: "X-User-Token"))
        #expect(!token.isEmpty)
        #expect(UUID(uuidString: token) != nil)
    }

    @Test func submitIdentityMatchesUploadSessionIdentity() async throws {
        let requests = CaptureBox<[URLRequest]>()
        MockURLProtocol.requestHandler = { request in
            requests.value = (requests.value ?? []) + [request]
            if request.url?.path == "/api/v1/uploads/sessions" {
                return (makeHTTPResponse(status: 201), try encodeJSON(self.sessionJSON))
            } else if request.url?.path == "/api/v1/uploads/upl-1" {
                return (makeHTTPResponse(status: 200), try encodeJSON(self.uploadedJSON))
            } else if request.url?.path == "/api/v1/feedback" {
                return (makeHTTPResponse(status: 200), try encodeJSON(["submissionId": "s-1"]))
            }
            return (makeHTTPResponse(status: 404), Data())
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        let attachment = try await client.uploadAttachment(
            data: Data("test".utf8),
            filename: "f.txt",
            mimeType: "text/plain",
            userToken: nil
        )

        var draft = FeedbackDraft(title: "T", description: "Desc ok", platform: .ios)
        draft.attachments = [attachment]
        _ = try await client.submit(draft, userToken: nil)

        let captured = try #require(requests.value)
        #expect(captured.count == 3)
        let sessionToken = try #require(captured[0].value(forHTTPHeaderField: "X-User-Token"))
        let submitToken = try #require(captured[2].value(forHTTPHeaderField: "X-User-Token"))
        #expect(!sessionToken.isEmpty)
        #expect(sessionToken == submitToken)
        #expect(sessionToken == UserTokenStore.shared.token)
    }

    @Test func sessionCreateRejects415WithTypedError() async throws {
        MockURLProtocol.requestHandler = { _ in
            return (
                makeHTTPResponse(status: 415),
                try encodeJSON(["error": "File content type does not match verified magic bytes"])
            )
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        do {
            _ = try await client.uploadAttachment(
                data: Data("test".utf8), filename: "f.txt", mimeType: "text/plain", userToken: "tok"
            )
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .unsupportedMediaType(let message) = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(message?.contains("magic bytes") == true)
        }
    }

    @Test func sessionCreateRejects429WithTypedError() async throws {
        MockURLProtocol.requestHandler = { _ in
            return (makeHTTPResponse(status: 429), try encodeJSON(["error": "Daily upload byte limit exceeded"]))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        do {
            _ = try await client.uploadAttachment(
                data: Data("test".utf8), filename: "f.txt", mimeType: "text/plain", userToken: "tok"
            )
            Issue.record("Expected error to be thrown")
        } catch FeedbackClientError.rateLimited {
            // expected
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func sessionCreateSurfacesUploaderIdentityError() async throws {
        MockURLProtocol.requestHandler = { _ in
            return (
                makeHTTPResponse(status: 400),
                try encodeJSON([
                    "error": "A valid X-User-Token UUID is required to create an upload session when not signed in",
                    "code": "uploader_identity_required"
                ])
            )
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        do {
            _ = try await client.createUploadSession(
                files: [FeedbackUploadFileSpec(clientFileId: "f", filename: "f.txt", contentType: "text/plain", sizeBytes: 4)],
                userToken: "not-a-uuid"
            )
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .uploaderIdentityRequired = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
        }
    }

    @Test func uploadThrowsScanRejectedWhenServerReturns422WithScanRejectedCode() async throws {
        let errorPayload: [String: Any] = [
            "error": "Upload object upl_bad_file was rejected by content scan: prohibited file type",
            "code": "scan_rejected"
        ]
        MockURLProtocol.requestHandler = { _ in
            (makeHTTPResponse(status: 422), try encodeJSON(errorPayload))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        do {
            _ = try await client.uploadAttachment(
                data: Data("test".utf8),
                filename: "bad.exe",
                mimeType: "application/octet-stream"
            )
            Issue.record("Expected scanRejected error to be thrown")
        } catch let error as FeedbackClientError {
            if case .scanRejected(let message) = error {
                #expect(message.contains("upl_bad_file"))
                #expect(message.contains("prohibited file type"))
                let desc = try #require(error.errorDescription)
                #expect(desc.contains("The referenced attachment could not be uploaded due to content inspection rejection"))
                #expect(desc.contains("prohibited file type"))
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    @Test func putSurfacesUploaderMismatchError() async throws {
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "POST" {
                return (makeHTTPResponse(status: 201), try encodeJSON(self.sessionJSON))
            }
            return (
                makeHTTPResponse(status: 400),
                try encodeJSON(["error": "Upload session was created by a different uploader", "code": "uploader_mismatch"])
            )
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        do {
            _ = try await client.uploadAttachment(
                data: Data("test".utf8), filename: "f.txt", mimeType: "text/plain", userToken: "tok"
            )
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .uploaderMismatch = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
        }
    }

    @Test func oversizedSlotLimitThrowsBeforeUpload() async throws {
        var session = self.sessionJSON
        session["files"] = [[
            "clientFileId": "file-1",
            "uploadId": "upl-1",
            "uploadUrl": "https://test.example.com/api/v1/uploads/upl-1",
            "maxSizeBytes": 2
        ]]

        let putReached = CaptureBox<Bool>()
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "POST" {
                return (makeHTTPResponse(status: 201), try encodeJSON(session))
            }
            putReached.value = true
            return (makeHTTPResponse(), try encodeJSON(self.uploadedJSON))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        do {
            _ = try await client.uploadAttachment(
                data: Data("toolarge".utf8), filename: "f.txt", mimeType: "text/plain", userToken: "tok"
            )
            Issue.record("Expected error to be thrown")
        } catch FeedbackClientError.payloadTooLarge {
            #expect(putReached.value != true)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func createUploadSessionDecodesDocumentedResponseShape() async throws {
        MockURLProtocol.requestHandler = { _ in
            return (makeHTTPResponse(status: 201), try encodeJSON(self.sessionJSON))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        let session = try await client.createUploadSession(
            files: [FeedbackUploadFileSpec(clientFileId: "file-1", filename: "f.txt", contentType: "text/plain", sizeBytes: 4)],
            userToken: "tok"
        )
        #expect(session.session.sessionId == "sess-1")
        #expect(session.session.sessionToken == "stok-abc")
        #expect(session.session.maxFileSizeBytes == 20_000_000)
        #expect(session.files.first?.uploadId == "upl-1")
        #expect(session.files.first?.maxSizeBytes == 20_000_000)
    }

    @Test func uploadSendsXRequestIDOnEveryRequest() async throws {
        let requests = CaptureBox<[URLRequest]>()
        MockURLProtocol.requestHandler = { request in
            requests.value = (requests.value ?? []) + [request]
            if request.httpMethod == "POST" {
                return (makeHTTPResponse(status: 201), try encodeJSON(self.sessionJSON))
            }
            return (makeHTTPResponse(), try encodeJSON(self.uploadedJSON))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        _ = try await client.uploadAttachment(
            data: Data("test".utf8), filename: "f.txt", mimeType: "text/plain", userToken: "tok"
        )

        let captured = try #require(requests.value)
        let ids = captured.compactMap { $0.value(forHTTPHeaderField: "X-Request-Id") }
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2) // per-request UUIDs
    }
} // end FeedbackClientUploadTests

} // end FeedbackClientTests
