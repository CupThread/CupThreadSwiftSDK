import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Anonymous token transport contract (#29)

/// One authenticated client call: how to perform it against the mock host and
/// what the mocked endpoint answers.
enum AuthenticatedEndpoint: String, CaseIterable, Sendable {
    case feedbackSubmit
    case createUploadSession
    case uploadSessionSlotPut
    case fetchFeatureRequests
    case submitFeatureRequest
    case toggleVote
    case postComment
    case subscribeToChangelog
    case updateUserAttributes
    case eraseMyData
    case linkEndUser

    /// HTTP status the mocked endpoint answers with (uploads/sessions is 201).
    var successStatus: Int {
        self == .createUploadSession ? 201 : 200
    }

    /// Whether the call presents the anonymous identity as `X-User-Token`.
    /// The session-slot PUT instead authenticates with the session's bearer
    /// token; `submit` omits the header for anonymous no-attachment drafts
    /// (already pinned by PublicAPITests).
    var sendsIdentityHeader: Bool {
        self != .uploadSessionSlotPut
    }

    func responseBody() throws -> Data {
        switch self {
        case .createUploadSession:
            return try Self.uploadSessionJSON()
        case .uploadSessionSlotPut:
            return try encodeJSON([
                "uploadId": "upl-1",
                "clientFileId": "file-1",
                "filename": "f.png",
                "contentType": "image/png",
                "sizeBytes": 2,
                "stored": true,
                "downloadUrl": "https://\(UserTokenTransportTests.host)/f.png"
            ])
        case .fetchFeatureRequests:
            return try encodeJSON(["requests": [String](), "total": 0])
        case .submitFeatureRequest:
            return try encodeJSON(["featureRequestId": "fr-1", "pending": true])
        case .postComment:
            return try encodeJSON([
                "id": "c-1",
                "featureRequestId": "fr-1",
                "body": "hi",
                "createdAt": "2026-09-18T00:00:00Z"
            ])
        case .updateUserAttributes:
            return try encodeJSON(["ok": true, "updatedAt": "2026-09-18T00:00:00Z"])
        case .eraseMyData:
            return try encodeJSON(["erased": true])
        case .linkEndUser:
            return try encodeJSON(["linked": true])
        case .feedbackSubmit, .toggleVote, .subscribeToChangelog:
            // All three decode leniently from an empty JSON object.
            return Data("{}".utf8)
        }
    }

    func perform(on client: FeedbackClient) async throws {
        switch self {
        case .feedbackSubmit, .createUploadSession, .uploadSessionSlotPut:
            try await performAttachmentFlow(on: client)
        case .fetchFeatureRequests, .submitFeatureRequest, .toggleVote, .postComment:
            try await performFeatureRequestFlow(on: client)
        case .subscribeToChangelog, .updateUserAttributes, .eraseMyData, .linkEndUser:
            try await performAccountFlow(on: client)
        }
    }

    private func performAttachmentFlow(on client: FeedbackClient) async throws {
        let token = UserTokenTransportTests.token
        switch self {
        case .feedbackSubmit:
            _ = try await client.submit(FeedbackDraft(platform: .ios), userToken: token)
        case .createUploadSession:
            _ = try await client.createUploadSession(
                files: [FeedbackUploadFileSpec(
                    clientFileId: "file-1",
                    filename: "f.png",
                    contentType: "image/png",
                    sizeBytes: 2
                )],
                userToken: token
            )
        case .uploadSessionSlotPut:
            let session = try JSONDecoder().decode(
                FeedbackUploadSession.self,
                from: Self.uploadSessionJSON()
            )
            _ = try await client.uploadAttachment(data: Data([0x89, 0x50]), contentType: "image/png", session: session)
        default:
            preconditionFailure("unsupported endpoint \(rawValue)")
        }
    }

    private func performFeatureRequestFlow(on client: FeedbackClient) async throws {
        let token = UserTokenTransportTests.token
        switch self {
        case .fetchFeatureRequests:
            _ = try await client.fetchFeatureRequests(userToken: token)
        case .submitFeatureRequest:
            _ = try await client.submitFeatureRequest(FeatureRequestDraft(title: "t", description: "d"), userToken: token)
        case .toggleVote:
            _ = try await client.toggleVote(featureRequestId: "fr-1", userToken: token)
        case .postComment:
            _ = try await client.postComment(featureRequestId: "fr-1", draft: CommentDraft(body: "hi"), userToken: token)
        default:
            preconditionFailure("unsupported endpoint \(rawValue)")
        }
    }

    private func performAccountFlow(on client: FeedbackClient) async throws {
        let token = UserTokenTransportTests.token
        switch self {
        case .subscribeToChangelog:
            _ = try await client.subscribeToChangelog(email: "reader@example.com", userToken: token)
        case .updateUserAttributes:
            _ = try await client.updateUserAttributes(plan: "pro", userToken: token)
        case .eraseMyData:
            _ = try await client.eraseMyData(userToken: token)
        case .linkEndUser:
            _ = try await client.linkEndUser(sessionToken: "sess-tok", userToken: token)
        default:
            preconditionFailure("unsupported endpoint \(rawValue)")
        }
    }

    private static func uploadSessionJSON() throws -> Data {
        try encodeJSON([
            "session": [
                "sessionId": "sess-1",
                "sessionToken": "stok-sess"
            ],
            "files": [[
                "clientFileId": "file-1",
                "uploadId": "upl-1",
                "uploadUrl": "https://\(UserTokenTransportTests.host)/api/v1/uploads/upl-1"
            ]]
        ])
    }
}

/// Regression sweep for #29: the persistent anonymous end-user token travels
/// exclusively in the `X-User-Token` header — never as a URL query parameter,
/// where server access logs, CDN logs, and URL caches would record it.
///
/// The parameterized case list covers every authenticated client method, so a
/// future endpoint that reintroduces a `userToken` query item (or any
/// URL-borne identity token) fails this suite. The end-to-end
/// `uploadAttachment(data:filename:mimeType:userToken:)` wrappers are not
/// separate cases: they issue exactly the session-create and slot-PUT
/// requests already swept here. `unsubscribeFromChangelog(token:)` is
/// deliberately excluded: its `token` query item is the RFC 8058 one-click
/// form's signed email token (an API contract), not the persistent identity.
@Suite("UserTokenTransport", .serialized)
struct UserTokenTransportTests {

    static let host = "token-transport.example.com"
    /// Distinctive value so an echo in a URL can never false-positive.
    static let token = "tok-sweep-4f7a9c"

    @Test(
        "Authenticated calls send the user token only in the X-User-Token header",
        arguments: AuthenticatedEndpoint.allCases
    )
    func tokenTravelsOnlyInHeader(_ endpoint: AuthenticatedEndpoint) async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = request
            return (makeHTTPResponse(status: endpoint.successStatus), try endpoint.responseBody())
        }
        let client = makeClient(baseURL: URL(string: "https://\(Self.host)")!)

        try await endpoint.perform(on: client)

        let request = try #require(capture.value, "no request captured for \(endpoint.rawValue)")
        let url = try #require(request.url)
        let queryNames = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name)
        if endpoint.sendsIdentityHeader {
            #expect(request.value(forHTTPHeaderField: "X-User-Token") == Self.token)
        }
        #expect(!queryNames.contains("userToken"))
        #expect(!url.absoluteString.contains(Self.token))
    }

    @Test("A blank user token omits the header and stays out of the query")
    func blankTokenKeepsRequestAnonymousAndClean() async throws {
        let capture = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(["requests": [String](), "total": 0]))
        }
        let client = makeClient(baseURL: URL(string: "https://\(Self.host)")!)

        _ = try await client.fetchFeatureRequests(userToken: "   ")

        let request = try #require(capture.value)
        #expect(request.value(forHTTPHeaderField: "X-User-Token") == nil)
        #expect(request.url?.query?.contains("userToken=") == false)
    }
}
