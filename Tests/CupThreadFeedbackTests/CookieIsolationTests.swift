import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Cookie isolation (#585)

/// The SDK's credential-isolation contract covers headers and bodies (SEC-11,
/// #284, #561, #571) but must also cover the ambient cookie channel (#585):
/// cookies the host app holds for the API origin must never attach to SDK
/// requests, and API `Set-Cookie` responses must never reach the host app's
/// shared cookie jar. The SDK reads no cookies, so the isolation costs
/// nothing.
///
/// The suites deliberately run their sessions through a configuration that
/// *opts into* the shared cookie jar (the worst case a host can present), so
/// the assertions prove the SDK's own isolation rather than relying on
/// Foundation's defaults.
@Suite("Cookie Isolation", .serialized)
struct CookieIsolationTests {

    /// 2×2 red PNG, the same fixture the loader suites use.
    private static let pngBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7gP9i18U1AAAAABJRU5ErkJggg=="

    private static func uniqueHost(_ label: String) -> String {
        "cookie-\(label)-\(UUID().uuidString.lowercased()).example.com"
    }

    /// A mock session that ships with the shared cookie jar and automatic
    /// cookie handling enabled — the configuration a host app's own session
    /// carries, so the tests exercise the SDK's isolation, not Foundation's
    /// defaults.
    private static func makeSharedJarSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        return URLSession(configuration: configuration)
    }

    /// Seeds an ambient cookie for `host` into the shared jar and returns it;
    /// the caller removes it with `HTTPCookieStorage.shared.deleteCookie(_)`.
    private static func seedAmbientCookie(host: String) -> HTTPCookie {
        let cookie = HTTPCookie(properties: [
            .domain: host,
            .path: "/",
            .name: "ambient_host_session",
            .value: "ambient-secret-value"
        ])!
        HTTPCookieStorage.shared.setCookie(cookie)
        return cookie
    }

    private static func sharedCookies(forHost host: String) -> [HTTPCookie] {
        HTTPCookieStorage.shared.cookies(
            for: URL(string: "https://\(host)/")!
        ) ?? []
    }

    // MARK: Default session configuration

    @Test("defaultSession carries no auto cookies and a private, empty jar")
    func defaultSessionIsCookieIsolated() {
        let configuration = FeedbackClient.defaultSession.configuration

        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieStorage !== HTTPCookieStorage.shared)
        #expect(configuration.httpCookieStorage?.cookies?.isEmpty != false)
    }

    // MARK: Outbound isolation — ambient cookies never attach

    @Test("SDK requests through a shared-jar session carry no Cookie header")
    func ambientCookiesNeverAttachToSDKRequests() async throws {
        let host = Self.uniqueHost("outbound")
        let ambient = Self.seedAmbientCookie(host: host)
        defer { HTTPCookieStorage.shared.deleteCookie(ambient) }

        let captured = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: host) { request in
            captured.value = request
            return (makeHTTPResponse(status: 200), try encodeJSON(makeConfigJSON()))
        }

        let client = FeedbackClient(
            configuration: FeedbackClientConfiguration(
                baseURL: URL(string: "https://\(host)")!,
                appKey: "app_testkey123456"
            ),
            session: Self.makeSharedJarSession()
        )
        _ = try await client.fetchAppConfig()

        let request = try #require(captured.value)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test("the upload PUT carries no ambient cookies either")
    func ambientCookiesNeverAttachToUploadPUTs() async throws {
        let host = Self.uniqueHost("upload")
        let ambient = Self.seedAmbientCookie(host: host)
        defer { HTTPCookieStorage.shared.deleteCookie(ambient) }

        let sessionJSON: [String: Any] = [
            "session": [
                "sessionId": "sess-1",
                "sessionToken": "stok-abc",
                "expiresAt": "2026-09-30T12:00:00Z",
                "maxFileSizeBytes": 20_000_000,
                "maxFiles": 8
            ],
            "files": [[
                "clientFileId": "file-1",
                "uploadId": "upl-1",
                "uploadUrl": "https://\(host)/api/v1/uploads/upl-1",
                "maxSizeBytes": 20_000_000
            ]]
        ]
        let uploadedJSON: [String: Any] = [
            "uploadId": "upl-1",
            "clientFileId": "file-1",
            "filename": "f.png",
            "contentType": "image/png",
            "sizeBytes": 5,
            "stored": true,
            "downloadUrl": "https://\(host)/f.png"
        ]

        let captured = CaptureBox<[URLRequest]>()
        MockURLProtocol.setHandler(forHost: host) { [sessionJSON, uploadedJSON] request in
            captured.value = (captured.value ?? []) + [request]
            if request.url?.path == "/api/v1/uploads/sessions" {
                return (makeHTTPResponse(status: 201), try encodeJSON(sessionJSON))
            }
            return (makeHTTPResponse(status: 200), try encodeJSON(uploadedJSON))
        }

        let client = FeedbackClient(
            configuration: FeedbackClientConfiguration(
                baseURL: URL(string: "https://\(host)")!,
                appKey: "app_testkey123456"
            ),
            session: Self.makeSharedJarSession()
        )
        _ = try await client.uploadAttachment(
            data: Data("hello".utf8), filename: "f.png", mimeType: "image/png", userToken: nil
        )

        let requests = try #require(captured.value)
        let put = try #require(requests.last)
        #expect(put.httpMethod == "PUT")
        #expect(put.httpShouldHandleCookies == false)
        #expect(put.value(forHTTPHeaderField: "Cookie") == nil)
    }

    // MARK: Inbound isolation — Set-Cookie never reaches the shared jar

    @Test("API Set-Cookie responses never reach the shared jar")
    func setCookieResponsesNeverReachTheSharedJar() async throws {
        let host = Self.uniqueHost("inbound")
        let ambient = Self.seedAmbientCookie(host: host)
        defer { HTTPCookieStorage.shared.deleteCookie(ambient) }

        MockURLProtocol.setHandler(forHost: host) { _ in
            let response = makeHTTPResponse(
                status: 200,
                headers: ["Set-Cookie": "planted_by_api=p0ison; Path=/"]
            )
            return (response, try encodeJSON(makeConfigJSON()))
        }

        let client = FeedbackClient(
            configuration: FeedbackClientConfiguration(
                baseURL: URL(string: "https://\(host)")!,
                appKey: "app_testkey123456"
            ),
            session: Self.makeSharedJarSession()
        )
        _ = try await client.fetchAppConfig()

        // Cookie storage processing trails response delivery; give it a
        // bounded window before asserting the jar stayed untouched.
        try await Task.sleep(for: .milliseconds(200))

        let cookies = Self.sharedCookies(forHost: host)
        #expect(cookies.map(\.name) == ["ambient_host_session"])
        #expect(!cookies.contains { $0.name == "planted_by_api" })
    }
}

// MARK: - RemoteImageLoader cookie isolation (#585)

@Suite(.serialized)
@MainActor
struct RemoteImageLoaderCookieIsolationTests {

    private static let pngBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7gP9i18U1AAAAABJRU5ErkJggg=="

    @Test("image fetches run on a cookie-isolated session, never the shared jar")
    func imageFetchesStayOutOfTheSharedJar() async throws {
        let host = "cookie-image-\(UUID().uuidString.lowercased()).example.com"
        let cookie = HTTPCookie(properties: [
            .domain: host,
            .path: "/",
            .name: "ambient_host_session",
            .value: "ambient-secret-value"
        ])!
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }

        let captured = CaptureBox<URLRequest>()
        MockURLProtocol.setHandler(forHost: host) { request in
            captured.value = request
            // The response must carry the request's URL: the loader's
            // transport re-checks the final response origin against the
            // request origin (SEC-31) and refuses anything else.
            let response = makeHTTPResponse(
                status: 200,
                url: request.url!,
                headers: ["Set-Cookie": "planted_by_api=p0ison; Path=/"]
            )
            return (response, Data(base64Encoded: Self.pngBase64)!)
        }

        // The injected session opts into the shared jar; the loader must
        // rebuild its own session out of that channel regardless (#585).
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        let loader = RemoteImageLoader(session: URLSession(configuration: configuration))

        let url = URL(string: "https://\(host)/avatar.png")!
        _ = try await loader.image(for: url)

        // The load-bearing assertions: the rebuilt session must refuse
        // automatic cookies and carry a private jar even when the injected
        // session opted into the shared one (#585).
        #expect(loader.sessionDisablesAutomaticCookies)
        #expect(loader.sessionUsesAPrivateCookieJar)

        let request = try #require(captured.value)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)

        // Cookie storage processing trails response delivery; give it a
        // bounded window before asserting the jar stayed untouched.
        try await Task.sleep(for: .milliseconds(200))

        let cookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://\(host)/")!) ?? []
        #expect(cookies.map(\.name) == ["ambient_host_session"])
        #expect(!cookies.contains { $0.name == "planted_by_api" })
    }
}
