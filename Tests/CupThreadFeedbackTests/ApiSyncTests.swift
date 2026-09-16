import Foundation
import ImageIO
import Testing
@testable import CupThreadFeedback
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// swiftlint:disable file_length

// MARK: - Metadata redaction contract (client-side, PRIV-01)

@Suite("FeedbackMetadataSanitizer")
struct FeedbackMetadataSanitizerTests {
    @Test func keepsValidKeysAndValues() {
        let sanitized = FeedbackMetadataSanitizer.sanitize([
            "device": "iPhone 15",
            "os_version": "17.2",
            "app-scope:id": "42"
        ])
        #expect(sanitized == [
            "device": "iPhone 15",
            "os_version": "17.2",
            "app-scope:id": "42"
        ])
    }

    @Test func dropsKeysWithDisallowedCharacters() {
        let sanitized = FeedbackMetadataSanitizer.sanitize([
            "ok.key:1": "v",
            "bad key": "v",
            "bad/slash": "v",
            "bad+plus": "v",
            "": "v"
        ])
        #expect(sanitized == ["ok.key:1": "v"])
    }

    @Test func dropsKeysOver64Characters() {
        let longKey = String(repeating: "a", count: 65)
        let sanitized = FeedbackMetadataSanitizer.sanitize([longKey: "v", "short": "v"])
        #expect(sanitized == ["short": "v"])
    }

    @Test func redactsCredentialLookingKeys() {
        let sanitized = FeedbackMetadataSanitizer.sanitize([
            "sessionToken": "s3cret",
            "API_KEY": "k",
            "user-password": "p",
            "cookie": "c",
            "authorization": "Bearer x",
            "note": "fine"
        ])
        #expect(sanitized["sessionToken"] == "[redacted]")
        #expect(sanitized["API_KEY"] == "[redacted]")
        #expect(sanitized["user-password"] == "[redacted]")
        #expect(sanitized["cookie"] == "[redacted]")
        #expect(sanitized["authorization"] == "[redacted]")
        #expect(sanitized["note"] == "fine")
    }

    @Test func truncatesValuesTo512Characters() {
        let sanitized = FeedbackMetadataSanitizer.sanitize(["log": String(repeating: "x", count: 600)])
        #expect(sanitized["log"]?.count == 512)
    }

    @Test func capsKeyCountAt24Deterministically() {
        var metadata: [String: String] = [:]
        for index in 0..<30 {
            metadata[String(format: "key%02d", index)] = "v\(index)"
        }
        let sanitized = FeedbackMetadataSanitizer.sanitize(metadata)
        #expect(sanitized.count == 24)
        // Sorted order: keys 00–23 survive deterministically.
        #expect(sanitized["key00"] == "v0")
        #expect(sanitized["key23"] == "v23")
        #expect(sanitized["key24"] == nil)
    }

    @Test func capsSerializedSizeAt8KBDroppingSortedKeys() {
        // 24 keys × 400 chars ≈ 9.6 KB serialized → must shrink below 8 KB.
        var metadata: [String: String] = [:]
        for index in 0..<24 {
            metadata[String(format: "key%02d", index)] = String(repeating: "y", count: 400)
        }
        let sanitized = FeedbackMetadataSanitizer.sanitize(metadata)
        let serialized = try? JSONEncoder().encode(sanitized)
        #expect((serialized?.count ?? .max) <= FeedbackMetadataSanitizer.maxTotalBytes)
        #expect(sanitized.count < 24)
    }

    @Test func sdkKeysSurviveDefaultMetadataSanitization() {
        let sanitized = FeedbackMetadataSanitizer.sanitize([
            "sdk": "cupthread-apple",
            "platform": "ios",
            "submittedAt": "2026-09-13T00:00:00.000Z"
        ])
        #expect(sanitized["sdk"] == "cupthread-apple")
        #expect(sanitized["platform"] == "ios")
        #expect(sanitized["submittedAt"] != "[redacted]")
    }

    @Test func sdkVersionKeysSurviveMetadataSanitization() {
        let sanitized = FeedbackMetadataSanitizer.sanitize([
            "sdk": FeedbackClient.sdkIdentifier,
            "sdkVersion": FeedbackClient.sdkVersion,
            "platform": "macos",
            "submittedAt": "2026-09-16T00:00:00.000Z"
        ])
        #expect(sanitized["sdk"] == "cupthread-apple/\(FeedbackClient.sdkVersion)")
        #expect(sanitized["sdkVersion"] == FeedbackClient.sdkVersion)
        #expect(sanitized["platform"] == "macos")
        #expect(sanitized["submittedAt"] != "[redacted]")
    }
}

// MARK: - Feature request paging (cursor) + identity header

@Suite("FeatureRequestPaging", .serialized)
struct FeatureRequestPagingTests {
    static let apiHost = "apisync-paging.example.com"

    static func makeItemJSON(id: String) -> [String: Any] {
        [
            "id": id,
            "appId": "app-1",
            "title": "Request \(id)",
            "description": "Desc",
            "status": "in_progress",
            "approved": true,
            "voteCount": 3,
            "hasVoted": false,
            "isOwnRequest": false,
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-02T00:00:00Z"
        ]
    }

    @Test func listFetchSendsUserTokenHeaderInsteadOfQueryParameter() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON([
                "requests": [Self.makeItemJSON(id: "fr-1")],
                "total": 1
            ]))
        }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
        _ = try await client.fetchFeatureRequests(userToken: "tok-123", limit: 10, offset: 0)

        let request = try #require(capture.value)
        let url = try #require(request.url)
        #expect(request.value(forHTTPHeaderField: "X-User-Token") == "tok-123")
        let query = url.query ?? ""
        #expect(!query.contains("userToken="))
        #expect(query.contains("appKey="))
        #expect(query.contains("limit=10"))
        #expect(!query.contains("cursor="))
    }

    @Test func listFetchAppendsCursorParameter() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON([
                "requests": [],
                "total": 10,
                "hasMore": false,
                "nextCursor": NSNull()
            ]))
        }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
        _ = try await client.fetchFeatureRequests(userToken: "tok", cursor: "MjAyNi0w")

        let request = try #require(capture.value)
        #expect(request.url?.query?.contains("cursor=MjAyNi0w") == true)
    }

    @Test func listResultDecodesCursorPagingFields() throws {
        let json = Data("""
        {
            "requests": [],
            "total": 123,
            "hasMore": true,
            "nextCursor": "MjAyNi0w..."
        }
        """.utf8)

        let result = try JSONDecoder().decode(ListFeatureRequestsResult.self, from: json)
        #expect(result.total == 123)
        #expect(result.hasMore == true)
        #expect(result.nextCursor == "MjAyNi0w...")
    }

    @Test func listResultDefaultsPagingFieldsForOffsetResponses() throws {
        let json = Data("""
        {"requests": [], "total": 5}
        """.utf8)

        let result = try JSONDecoder().decode(ListFeatureRequestsResult.self, from: json)
        #expect(result.hasMore == false)
        #expect(result.nextCursor == nil)
    }

    @Test func voteResultDecodesSchemaHasVotedField() throws {
        let json = Data("""
        {"featureRequestId": "fr-1", "voteCount": 7, "hasVoted": true}
        """.utf8)

        let result = try JSONDecoder().decode(VoteResult.self, from: json)
        #expect(result.voted == true)
        #expect(result.voteCount == 7)
    }

    @Test func voteResultDecodesLegacyVotedField() throws {
        let json = Data("""
        {"voted": false, "voteCount": 2}
        """.utf8)

        let result = try JSONDecoder().decode(VoteResult.self, from: json)
        #expect(result.voted == false)
        #expect(result.voteCount == 2)
    }

    @Test func voteMaps429ToRateLimited() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 429), try encodeJSON(["error": "Too many votes. Please try again shortly."]))
        }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
        do {
            _ = try await client.toggleVote(featureRequestId: "fr-1", userToken: "tok")
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .rateLimited = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(error.errorDescription?.contains("try again in a minute") == true)
        }
    }

    @Test func searchMaps429ToRateLimitedNotRawBody() async throws {
        // Issue #59: the search endpoint is rate-limited per client IP; the
        // typed `.rateLimited` error (with its friendly message) must reach
        // the views instead of `unexpectedStatus` carrying the raw JSON body.
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 429), try encodeJSON(["error": "Too many searches. Please try again shortly."]))
        }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
        do {
            _ = try await client.fetchFeatureRequests(userToken: "tok", query: "sync")
            Issue.record("Expected error to be thrown")
        } catch let error as FeedbackClientError {
            guard case .rateLimited(let message) = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(message == "Too many searches. Please try again shortly.")
            #expect(error.errorDescription?.contains("try again in a minute") == true)
        }
    }

    @Test func voteSendsUserTokenHeader() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["featureRequestId": "fr-1", "voteCount": 1, "hasVoted": true]))
        }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!)
        _ = try await client.toggleVote(featureRequestId: "fr-1", userToken: "vote-tok")

        let request = try #require(capture.value)
        #expect(request.value(forHTTPHeaderField: "X-User-Token") == "vote-tok")
    }
}

// MARK: - List state pagination

@Suite("FeatureRequestsListStatePaging")
struct FeatureRequestsListStatePagingTests {
    private func makeItem(id: String) -> FeatureRequestItem {
        FeatureRequestItem(
            id: id,
            appId: "app-1",
            title: "Title \(id)",
            description: "",
            status: "new",
            approved: true,
            voteCount: 0,
            hasVoted: false,
            isOwnRequest: false,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z"
        )
    }

    @Test func replacingPageUpdatesCursorAndItems() {
        var state = FeatureRequestsListState(items: [makeItem(id: "old")])
        let result = ListFeatureRequestsResult(
            requests: [makeItem(id: "a"), makeItem(id: "b")],
            total: 100,
            hasMore: true,
            nextCursor: "cursor-1"
        )

        state.applyPage(result, replacesExisting: true)

        #expect(state.items.map(\.id) == ["a", "b"])
        #expect(state.nextCursor == "cursor-1")
        #expect(state.hasMorePages == true)
    }

    @Test func appendingPageDeduplicatesAndExtends() {
        var state = FeatureRequestsListState(items: [makeItem(id: "a")])
        state.applyPage(
            ListFeatureRequestsResult(requests: [makeItem(id: "a"), makeItem(id: "b")], total: 3, hasMore: false, nextCursor: nil),
            replacesExisting: true
        )
        state.applyPage(
            ListFeatureRequestsResult(requests: [makeItem(id: "b"), makeItem(id: "c")], total: 3, hasMore: false, nextCursor: nil),
            replacesExisting: false
        )

        #expect(state.items.map(\.id) == ["a", "b", "c"])
        #expect(state.hasMorePages == false)
        #expect(state.nextCursor == nil)
    }

    @Test func hasMoreWithoutCursorDoesNotOfferLoadMore() {
        var state = FeatureRequestsListState()
        state.applyPage(
            ListFeatureRequestsResult(requests: [makeItem(id: "a")], total: 60, hasMore: true, nextCursor: nil),
            replacesExisting: true
        )
        #expect(state.hasMorePages == false)
    }
}

// MARK: - Attachment media policy helpers (#41)

@Suite("PhotoAttachmentHelperMediaPolicy")
struct PhotoAttachmentHelperMediaPolicyTests {
    /// Encodes a real 1×1 solid-color PNG via ImageIO.
    private func makePNGData() -> Data? {
        let context = CGContext(
            data: nil, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let context,
              let image = context.makeImage() else {
            return nil
        }
        let mutableData = NSMutableData()
        let type: CFString
        #if canImport(UniformTypeIdentifiers)
        type = UTType.png.identifier as CFString
        #else
        type = "public.png" as CFString
        #endif
        guard let dest = CGImageDestinationCreateWithData(mutableData as CFMutableData, type, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    private func makeHEICData() -> Data {
        // ISO-BMPP header with a HEIC brand at offset 4.
        var data = Data([0x00, 0x00, 0x00, 0x18])
        data.append(Data("ftyp".utf8))
        data.append(Data("heic".utf8))
        data.append(Data([0x00, 0x00, 0x00, 0x00]))
        return data
    }

    @Test func detectsSVGSignaturesAndRejectsLocally() {
        #expect(PhotoAttachmentHelper.looksLikeSVG(Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)))
        #expect(PhotoAttachmentHelper.looksLikeSVG(Data("<?xml version=\"1.0\"?><svg xmlns=\"x\"></svg>".utf8)))
        #expect(PhotoAttachmentHelper.looksLikeSVG(Data("\n  <svg>".utf8)))
        #expect(PhotoAttachmentHelper.looksLikeSVG(Data([0xEF, 0xBB, 0xBF]) + Data("<svg>".utf8)))
        #expect(!PhotoAttachmentHelper.looksLikeSVG(Data("<html><body></body></html>".utf8)))
        #expect(!PhotoAttachmentHelper.looksLikeSVG(makePNGData() ?? Data()))
    }

    @Test func requiresJPEGTranscodeForHEICAndUnknownContainers() throws {
        let png = try #require(makePNGData())
        #expect(!PhotoAttachmentHelper.requiresJPEGTranscode(png))
        #expect(!PhotoAttachmentHelper.requiresJPEGTranscode(Data([0xFF, 0xD8, 0xFF, 0xE0])))
        #expect(PhotoAttachmentHelper.requiresJPEGTranscode(makeHEICData()))
        #expect(PhotoAttachmentHelper.requiresJPEGTranscode(Data("not an image".utf8)))
    }

    @Test func jpegTranscodeProducesJPEGMagicBytes() throws {
        let png = try #require(makePNGData())
        let jpeg = try #require(PhotoAttachmentHelper.jpegRepresentationResampled(from: png))
        #expect(jpeg.starts(with: [0xFF, 0xD8, 0xFF]))
        #expect(PhotoAttachmentHelper.sniffImageFormat(from: jpeg)?.mimeType == "image/jpeg")
    }

    @Test func jpegTranscodeReturnsNilForNonImageData() {
        #expect(PhotoAttachmentHelper.jpegRepresentationResampled(from: Data("definitely not an image".utf8)) == nil)
    }
}

// MARK: - App-scoped pseudonymous user identifiers (PRIV-06)

/// The server now emits app-scoped pseudonymous user identifiers (`u_*`)
/// on public payloads instead of global identity-provider IDs. The SDK must
/// parse, carry, and round-trip them verbatim without any `user_`-prefix or
/// cross-appKey assumptions.
@Suite("PseudonymousUserIdentifiers")
struct PseudonymousUserIdentifiersTests {
    static let pseudonym = "u_ab12cd34ef56"

    static func makeItemJSON() -> [String: Any] {
        [
            "id": "fr-1",
            "appId": "app-1",
            "title": "Request",
            "description": "Desc",
            "status": "new",
            "approved": true,
            "voteCount": 1,
            "hasVoted": false,
            "isOwnRequest": false,
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-01T00:00:00Z",
            "requesterClerkId": pseudonym,
            "recentCommenters": [[
                "authorName": "Alice",
                "clerkUserId": "u_9988aabb",
                "avatarUrl": "https://example.com/a.png"
            ]]
        ]
    }

    @Test func featureRequestItemDecodesPseudonymousIdsVerbatim() throws {
        let item = try JSONDecoder().decode(FeatureRequestItem.self, from: try encodeJSON(Self.makeItemJSON()))
        #expect(item.requesterClerkId == Self.pseudonym)
        #expect(item.recentCommenters.count == 1)
        #expect(item.recentCommenters[0].clerkUserId == "u_9988aabb")
        #expect(item.recentCommenters[0].authorName == "Alice")
    }

    @Test func commentsDecodePseudonymousAuthorAndReplyIds() throws {
        let json = Data("""
        {
            "comments": [
                {
                    "id": "c-1",
                    "featureRequestId": "fr-1",
                    "body": "Parent",
                    "authorClerkId": "u_ab12cd34ef56",
                    "createdAt": "2026-01-01T00:00:00.000Z"
                },
                {
                    "id": "c-2",
                    "featureRequestId": "fr-1",
                    "body": "Reply",
                    "authorClerkId": "u_deadbeef01",
                    "parentId": "c-1",
                    "replyToClerkId": "u_ab12cd34ef56",
                    "replyToAuthorName": "Alice",
                    "createdAt": "2026-01-02T00:00:00.000Z"
                }
            ]
        }
        """.utf8)

        let comments = try JSONDecoder().decode(ListCommentsResponse.self, from: json).comments
        let displayModels = comments.map(\.displayModel)
        #expect(displayModels[0].authorClerkId == "u_ab12cd34ef56")
        #expect(displayModels[0].canOpenAuthorProfile == true)
        #expect(displayModels[1].replyToClerkId == "u_ab12cd34ef56")
        #expect(displayModels[1].canReply == true)
    }

    @Test func postCommentSendsPseudonymousReplyIdAndDecodesPseudonymousResponse() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: "priv06-post.example.com") { request in
            capture.value = request
            return (makeHTTPResponse(status: 201), try encodeJSON([
                "id": "c-new",
                "featureRequestId": "fr-1",
                "body": "Reply body",
                "authorClerkId": "u_0123abcd",
                "parentId": "c-1",
                "replyToClerkId": Self.pseudonym,
                "replyToAuthorName": "Alice",
                "createdAt": "2026-01-03T00:00:00.000Z"
            ]))
        }

        var draft = CommentDraft(body: "Reply body", parentId: "c-1")
        draft.replyToClerkId = Self.pseudonym
        draft.replyToAuthorName = "Alice"

        let client = makeClient(baseURL: URL(string: "https://priv06-post.example.com")!)
        let created = try await client.postComment(featureRequestId: "fr-1", draft: draft, userToken: "tok")

        let request = try #require(capture.value)
        let rawBody = try #require(bodyData(from: request))
        let json = try #require(parseJSONDict(rawBody))
        #expect(json["replyToClerkId"] as? String == Self.pseudonym)
        #expect(created.authorClerkId == "u_0123abcd")
        #expect(created.replyToClerkId == Self.pseudonym)
    }

    @Test func fetchUserProfileBuildsPathFromPseudonymousId() async throws {
        let capture = CaptureBox<URL>()
        MockURLProtocol.setHandler(forHost: "priv06.example.com") { request in
            capture.value = request.url
            return (makeHTTPResponse(), try encodeJSON([
                "profile": ["clerkUserId": Self.pseudonym, "displayName": NSNull()],
                "publicApps": [],
                "recentComments": []
            ]))
        }

        let client = makeClient(baseURL: URL(string: "https://priv06.example.com")!)
        let response = try await client.fetchUserProfile(userId: Self.pseudonym)

        let url = try #require(capture.value)
        #expect(url.path == "/api/v1/users/\(Self.pseudonym)/profile")
        #expect(response.profile.clerkUserId == Self.pseudonym)
    }

    @Test func profileOptOutShapeDecodesWithNullDisplayNameAndEmptyCollections() throws {
        // Users without a public profile: displayName null, empty arrays.
        let json = Data("""
        {
            "profile": {
                "clerkUserId": "u_cafef00d",
                "displayName": null
            },
            "publicApps": [],
            "recentComments": []
        }
        """.utf8)

        let response = try JSONDecoder().decode(PublicUserProfileResponse.self, from: json)
        #expect(response.profile.clerkUserId == "u_cafef00d")
        #expect(response.profile.displayName == nil)
        #expect(response.publicApps.isEmpty)
        #expect(response.recentComments.isEmpty)
        #expect(response.hideComments == false)
    }

    @Test func pseudonymousIdsFromDifferentAppsAreNotAssumedRelated() throws {
        // Same pseudonym shape from two appKeys must decode independently;
        // the SDK treats them as opaque strings with no correlation logic.
        var first = Self.makeItemJSON()
        first["requesterClerkId"] = "u_apple1111"
        var second = Self.makeItemJSON()
        second["requesterClerkId"] = "u_banana2222"

        let firstItem = try JSONDecoder().decode(FeatureRequestItem.self, from: try encodeJSON(first))
        let secondItem = try JSONDecoder().decode(FeatureRequestItem.self, from: try encodeJSON(second))
        #expect(firstItem.requesterClerkId == "u_apple1111")
        #expect(secondItem.requesterClerkId == "u_banana2222")
        #expect(firstItem.requesterClerkId != secondItem.requesterClerkId)
    }
}

// MARK: - Legacy attachment decode compat

@Suite("FeedbackAttachmentDecodeCompat")
struct FeedbackAttachmentDecodeCompatTests {
    @Test func decodesLegacyJSONWithoutUploadID() throws {
        let json = Data("""
        {"kind": "image", "key": "img-key", "url": "https://example.com/a.png"}
        """.utf8)

        let attachment = try JSONDecoder().decode(FeedbackAttachment.self, from: json)
        #expect(attachment.uploadId == nil)
        #expect(attachment.key == "img-key")
        #expect(attachment.kind == .image)
    }

    @Test func encodesAndDecodesUploadIDRoundTrip() throws {
        let original = FeedbackAttachment(
            kind: .image,
            uploadId: "upl-9",
            key: "upl-9",
            url: URL(string: "https://example.com/a.png")!,
            filename: "a.png",
            mimeType: "image/png",
            size: 12
        )
        let decoded = try JSONDecoder().decode(FeedbackAttachment.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}
