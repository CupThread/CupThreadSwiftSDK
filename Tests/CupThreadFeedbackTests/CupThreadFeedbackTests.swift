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
        let error = FeedbackClientError.unexpectedStatus(code: 503, message: "Service Unavailable")
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("503"))
    }

    @Test func unexpectedStatusDescriptionContainsMessage() throws {
        let error = FeedbackClientError.unexpectedStatus(code: 503, message: "Service Unavailable")
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("Service Unavailable"))
    }

    @Test func unexpectedStatusWith400ContainsCode() throws {
        let error = FeedbackClientError.unexpectedStatus(code: 400, message: "Validation failed")
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("400"))
    }
}

// MARK: - FeedbackClient (serialized — tests share a static URLProtocol handler)

/// All FeedbackClient network tests run serially to prevent races on MockURLProtocol.requestHandler.
@Suite("FeedbackClient", .serialized)
// swiftlint:disable:next type_body_length
struct FeedbackClientTests {

// MARK: Submit

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

    @Test func errorStatusThrowsUnexpectedStatus() async throws {
        MockURLProtocol.requestHandler = { _ in
            return (makeHTTPResponse(status: 400), try encodeJSON(["error": "Validation failed"]))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        do {
            _ = try await client.submit(FeedbackDraft(title: "T", description: "Desc ok", platform: .ios))
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            if case .unexpectedStatus(let code, _) = error {
                #expect(code == 400)
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        }
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

} // end FeedbackClientSubmitTests

// MARK: Upload

struct FeedbackClientUploadTests {
    let baseURL = URL(string: "https://test.example.com")!
    let appKey = "app_testuploadkey1"

    private func makeR2Response() throws -> (HTTPURLResponse, Data) {
        let body: [String: Any] = [
            "kind": "r2", "key": "wk/file.txt",
            "url": "https://example.com/file.txt",
            "filename": "file.txt", "mimeType": "text/plain", "size": 4
        ]
        return (makeHTTPResponse(), try encodeJSON(body))
    }

    private func makeImageResponse() throws -> (HTTPURLResponse, Data) {
        let body: [String: Any] = [
            "kind": "image", "key": "img-key",
            "url": "https://example.com/img.png",
            "filename": "photo.png", "mimeType": "image/png", "size": 42
        ]
        return (makeHTTPResponse(), try encodeJSON(body))
    }

    @Test func imagesEndpointUsedForImageMimeType() async throws {
        let capture = CaptureBox<URL>()
        MockURLProtocol.requestHandler = { request in
            capture.value = request.url
            return try self.makeImageResponse()
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        _ = try await client.uploadAttachment(data: Data([0xFF, 0xD8]), filename: "photo.png", mimeType: "image/png")

        let url = try #require(capture.value)
        #expect(url.path == "/api/v1/uploads/images")
    }

    @Test func r2EndpointUsedForNonImageMimeType() async throws {
        let capture = CaptureBox<URL>()
        MockURLProtocol.requestHandler = { request in
            capture.value = request.url
            return try self.makeR2Response()
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        _ = try await client.uploadAttachment(data: Data("hello".utf8), filename: "doc.pdf", mimeType: "application/pdf")

        let url = try #require(capture.value)
        #expect(url.path == "/api/v1/uploads/r2")
    }

    @Test func r2EndpointUsedForPlainTextMimeType() async throws {
        let capture = CaptureBox<URL>()
        MockURLProtocol.requestHandler = { request in
            capture.value = request.url
            return try self.makeR2Response()
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        _ = try await client.uploadAttachment(data: Data("text".utf8), filename: "log.txt", mimeType: "text/plain")

        let url = try #require(capture.value)
        #expect(url.path == "/api/v1/uploads/r2")
    }

    @Test func preferredKindOverridesAutoDetection() async throws {
        let capture = CaptureBox<URL>()
        MockURLProtocol.requestHandler = { request in
            capture.value = request.url
            return try self.makeR2Response()
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        // Force r2 even though mimeType is image/png
        _ = try await client.uploadAttachment(data: Data([0xFF, 0xD8]), filename: "img.png", mimeType: "image/png", preferredKind: .r2)

        let url = try #require(capture.value)
        #expect(url.path == "/api/v1/uploads/r2")
    }

    @Test func requestContentTypeIsMultipartFormData() async throws {
        let capture = CaptureBox<String>()
        MockURLProtocol.requestHandler = { request in
            capture.value = request.value(forHTTPHeaderField: "Content-Type")
            return try self.makeR2Response()
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        _ = try await client.uploadAttachment(data: Data("test".utf8), filename: "f.txt", mimeType: "text/plain")

        let ct = try #require(capture.value)
        #expect(ct.hasPrefix("multipart/form-data"))
    }

    @Test func multipartBodyContainsAppKey() async throws {
        let theAppKey = "app_verifiableuploadkey"
        let capture = CaptureBox<String>()
        MockURLProtocol.requestHandler = { request in
            if let data = bodyData(from: request) {
                capture.value = String(data: data, encoding: .utf8)
            }
            return try self.makeR2Response()
        }

        let client = makeClient(baseURL: baseURL, appKey: theAppKey)
        _ = try await client.uploadAttachment(data: Data("hi".utf8), filename: "f.txt", mimeType: "text/plain")

        let body = try #require(capture.value)
        #expect(body.contains(theAppKey))
    }

    @Test func successfulResponseReturnsR2Attachment() async throws {
        MockURLProtocol.requestHandler = { _ in
            let body: [String: Any] = [
                "kind": "r2", "key": "workspace/file.txt",
                "url": "https://example.com/workspace/file.txt",
                "filename": "file.txt", "mimeType": "text/plain", "size": 128
            ]
            return (makeHTTPResponse(), try encodeJSON(body))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        let attachment = try await client.uploadAttachment(data: Data("content".utf8), filename: "file.txt", mimeType: "text/plain")

        #expect(attachment.kind == .r2)
        #expect(attachment.key == "workspace/file.txt")
        #expect(attachment.filename == "file.txt")
        #expect(attachment.size == 128)
    }

    @Test func successfulResponseReturnsImageAttachment() async throws {
        MockURLProtocol.requestHandler = { _ in
            let body: [String: Any] = [
                "kind": "image", "key": "img-uuid-1",
                "url": "https://imagedelivery.net/img-uuid-1/public",
                "filename": "screenshot.png", "mimeType": "image/png", "size": 512
            ]
            return (makeHTTPResponse(), try encodeJSON(body))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        let attachment = try await client.uploadAttachment(data: Data([0xFF, 0xD8]), filename: "screenshot.png", mimeType: "image/png")

        #expect(attachment.kind == .image)
        #expect(attachment.key == "img-uuid-1")
    }

    @Test func errorResponseThrowsUnexpectedStatus() async throws {
        MockURLProtocol.requestHandler = { _ in
            return (makeHTTPResponse(status: 413), try encodeJSON(["error": "File too large"]))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        do {
            _ = try await client.uploadAttachment(data: Data("large".utf8), filename: "f.txt", mimeType: "text/plain")
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            if case .unexpectedStatus(let code, _) = error {
                #expect(code == 413)
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    @Test func uploadSetsUserTokenHeaderWhenProvided() async throws {
        let capture = CaptureBox<String?>()
        MockURLProtocol.requestHandler = { request in
            capture.value = request.value(forHTTPHeaderField: "X-User-Token")
            return try self.makeR2Response()
        }

        let token = "user_token_abc123"
        let client = makeClient(baseURL: baseURL, appKey: appKey)
        _ = try await client.uploadAttachment(
            data: Data("test".utf8),
            filename: "f.txt",
            mimeType: "text/plain",
            userToken: token
        )

        #expect(capture.value == token)
    }

    @Test func uploadOmitsUserTokenHeaderWhenNilOrEmpty() async throws {
        let capture = CaptureBox<String>()
        MockURLProtocol.requestHandler = { request in
            capture.value = request.value(forHTTPHeaderField: "X-User-Token") ?? ""
            return try self.makeR2Response()
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        _ = try await client.uploadAttachment(
            data: Data("test".utf8),
            filename: "f.txt",
            mimeType: "text/plain",
            userToken: nil
        )
        #expect((capture.value ?? "").isEmpty)

        _ = try await client.uploadAttachment(
            data: Data("test".utf8),
            filename: "f.txt",
            mimeType: "text/plain",
            userToken: "   \n\t "
        )
        #expect((capture.value ?? "").isEmpty)
    }

    @Test func successfulResponseWith201StatusReturnsAttachment() async throws {
        MockURLProtocol.requestHandler = { _ in
            let body: [String: Any] = [
                "kind": "image", "key": "img-201-created",
                "url": "https://imagedelivery.net/img-201-created/public",
                "filename": "screenshot.png", "mimeType": "image/png", "size": 1024
            ]
            return (makeHTTPResponse(status: 201), try encodeJSON(body))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        let attachment = try await client.uploadAttachment(
            data: Data([0xFF, 0xD8]),
            filename: "screenshot.png",
            mimeType: "image/png",
            userToken: "user-tok"
        )

        #expect(attachment.kind == .image)
        #expect(attachment.key == "img-201-created")
        #expect(attachment.size == 1024)
    }

    @Test func successfulResponseWith202StatusReturnsAttachment() async throws {
        MockURLProtocol.requestHandler = { _ in
            let body: [String: Any] = [
                "kind": "r2", "key": "async-key",
                "url": "https://example.com/async-key",
                "filename": "dump.log", "mimeType": "text/plain", "size": 2048
            ]
            return (makeHTTPResponse(status: 202), try encodeJSON(body))
        }

        let client = makeClient(baseURL: baseURL, appKey: appKey)
        let attachment = try await client.uploadAttachment(
            data: Data("log data".utf8),
            filename: "dump.log",
            mimeType: "text/plain"
        )

        #expect(attachment.kind == .r2)
        #expect(attachment.key == "async-key")
        #expect(attachment.size == 2048)
    }
} // end FeedbackClientUploadTests

} // end FeedbackClientTests
