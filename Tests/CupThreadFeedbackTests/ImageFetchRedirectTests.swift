import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - Image fetch redirect policy (SEC-31, follow-up to #284)

/// URLProtocol stub that can answer with a final response or a simulated 3xx.
///
/// A URLProtocol-simulated redirect that the delegate refuses never completes
/// (an artifact of the simulation, not of real networking: CFNetwork delivers
/// the 3xx as the final response once the delegate returns `nil`). This stub
/// therefore mirrors the shipped policy: an allowed redirect is handed to
/// URLSession's real redirect machinery, while an off-origin one is delivered
/// as the final 3xx. The delegate's own refuse/follow decision is pinned
/// separately, so the end-to-end assertions still prove the target is never
/// contacted.
private final class ImageRedirectStubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Outcome {
        case respond(Int, Data)
        case redirect(status: Int, location: URL)
    }

    typealias Handler = (URLRequest) throws -> Outcome

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func setHandler(forHost host: String, _ handler: Handler?) {
        lock.lock()
        defer { lock.unlock() }
        handlers[host] = handler
    }

    private static func handler(forHost host: String) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[host]
    }

    // URLProtocol requires class-func overrides; `static` would not dispatch
    // through the ObjC runtime. swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler(forHost: request.url?.host ?? "") else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            switch try handler(request) {
            case .respond(let status, let data):
                let response = Self.response(status, request.url)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            case .redirect(let status, let location):
                let redirectResponse = Self.response(status, request.url, location: location)
                if ImageFetchRedirectPolicy.isAllowed(originalURL: request.url, redirectURL: location) {
                    client?.urlProtocol(
                        self,
                        wasRedirectedTo: URLRequest(url: location),
                        redirectResponse: redirectResponse
                    )
                } else {
                    client?.urlProtocol(self, didReceive: redirectResponse, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocolDidFinishLoading(self)
                }
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func response(
        _ status: Int,
        _ url: URL?,
        location: URL? = nil
    ) -> HTTPURLResponse {
        var headers = ["Content-Type": "image/png"]
        if let location {
            headers["Location"] = location.absoluteString
        }
        return HTTPURLResponse(
            url: url ?? URL(string: "https://invalid.example.com")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
    }
}

@Suite("ImageFetchRedirect", .serialized)
@MainActor
struct ImageFetchRedirectTests {
    private static let host = "image-redirect.test.example.com"
    private static let evilHost = "evil-image-redirect.test.example.com"
    private static let pngBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7gP9i18U1AAAAABJRU5ErkJggg=="

    private var startURL: URL { URL(string: "https://\(Self.host)/avatar.png")! }
    private var evilURL: URL { URL(string: "https://\(Self.evilHost)/steal.png")! }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageRedirectStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func removeHandlers() {
        ImageRedirectStubURLProtocol.setHandler(forHost: Self.host, nil)
        ImageRedirectStubURLProtocol.setHandler(forHost: Self.evilHost, nil)
        ImageRedirectStubURLProtocol.setHandler(forHost: "cdn.\(Self.host)", nil)
    }

    // MARK: Policy decisions

    @Test func sameOriginHTTPSRedirectIsAllowed() {
        let start = URL(string: "https://api.example.com/a.png")!

        #expect(ImageFetchRedirectPolicy.isAllowed(
            originalURL: start,
            redirectURL: URL(string: "https://api.example.com/b.png")!
        ))
        // Host comparison is case-insensitive.
        #expect(ImageFetchRedirectPolicy.isAllowed(
            originalURL: start,
            redirectURL: URL(string: "https://API.EXAMPLE.COM/b.png")!
        ))
        // An explicit default port is the same effective origin.
        #expect(ImageFetchRedirectPolicy.isAllowed(
            originalURL: start,
            redirectURL: URL(string: "https://api.example.com:443/b.png")!
        ))
        let explicitDefaultPort = URL(string: "https://api.example.com:443/a.png")!
        #expect(ImageFetchRedirectPolicy.isAllowed(originalURL: explicitDefaultPort, redirectURL: start))
    }

    @Test func crossOriginOrInsecureRedirectsAreRefused() {
        let start = URL(string: "https://api.example.com/a.png")!

        // Plaintext downgrade, host change, subdomain widening, port change.
        #expect(!ImageFetchRedirectPolicy.isAllowed(
            originalURL: start,
            redirectURL: URL(string: "http://api.example.com/a.png")!
        ))
        #expect(!ImageFetchRedirectPolicy.isAllowed(
            originalURL: start,
            redirectURL: URL(string: "https://evil.example.com/a.png")!
        ))
        #expect(!ImageFetchRedirectPolicy.isAllowed(
            originalURL: start,
            redirectURL: URL(string: "https://cdn.api.example.com/a.png")!
        ))
        #expect(!ImageFetchRedirectPolicy.isAllowed(
            originalURL: start,
            redirectURL: URL(string: "https://api.example.com:8443/a.png")!
        ))
        #expect(!ImageFetchRedirectPolicy.isAllowed(
            originalURL: URL(string: "https://api.example.com:8443/a.png")!,
            redirectURL: start
        ))

        // Embedded credentials are never accepted, on either side.
        let credentialed = URL(string: "https://user:secret@api.example.com/a.png")!
        #expect(!ImageFetchRedirectPolicy.isAllowed(originalURL: start, redirectURL: credentialed))
        #expect(!ImageFetchRedirectPolicy.isAllowed(originalURL: credentialed, redirectURL: start))

        // Missing or unusable URLs fail closed.
        #expect(!ImageFetchRedirectPolicy.isAllowed(originalURL: nil, redirectURL: start))
        #expect(!ImageFetchRedirectPolicy.isAllowed(originalURL: start, redirectURL: nil))
        #expect(!ImageFetchRedirectPolicy.isAllowed(
            originalURL: start,
            redirectURL: URL(string: "mailto:user@example.com")
        ))
    }

    // MARK: Delegate decision

    /// Pins the transport's delegate decision directly: a cross-origin hop
    /// gets `nil` (refused; URLSession then delivers the 3xx as the final
    /// response), a same-origin one gets the proposed request.
    @Test func redirectDelegateRefusesOffOriginAndFollowsSameOrigin() throws {
        let transport = BoundedBodyTransport()
        let response = HTTPURLResponse(
            url: startURL,
            statusCode: 302,
            httpVersion: nil,
            headerFields: nil
        )!

        func decision(for redirectURL: String) throws -> (called: Bool, followed: URLRequest?) {
            let original = URLRequest(url: startURL)
            // An unstarted task carries its `originalRequest`, which is all
            // the delegate reads once no transfer is registered.
            let task = URLSession.shared.dataTask(with: original)
            defer { task.cancel() }
            let proposed = URLRequest(url: URL(string: redirectURL)!)
            let calledBox = CaptureBox<Bool>()
            let followedBox = CaptureBox<URLRequest?>()
            transport.urlSession(
                URLSession.shared,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: proposed,
                completionHandler: { followed in
                    calledBox.value = true
                    followedBox.value = followed
                }
            )
            return (calledBox.value == true, followedBox.value ?? nil)
        }

        let refused = try decision(for: "https://\(Self.evilHost)/steal.png")
        #expect(refused.called)
        #expect(refused.followed == nil)

        let downgraded = try decision(for: "http://\(Self.host)/plain.png")
        #expect(downgraded.called)
        #expect(downgraded.followed == nil)

        let portChanged = try decision(for: "https://\(Self.host):8443/port.png")
        #expect(portChanged.called)
        #expect(portChanged.followed == nil)

        let followed = try decision(for: "https://\(Self.host)/next.png")
        #expect(followed.called)
        #expect(followed.followed?.url == URL(string: "https://\(Self.host)/next.png"))
    }

    /// Defense in depth: even if a response from another origin reaches the
    /// transport, it is cancelled before any body bytes are buffered.
    @Test func finalResponseFromAnotherOriginIsCancelled() {
        let transport = BoundedBodyTransport()
        let task = URLSession.shared.dataTask(with: URLRequest(url: startURL))
        defer { task.cancel() }
        let foreignResponse = HTTPURLResponse(
            url: evilURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
        )!
        let dispositionBox = CaptureBox<URLSession.ResponseDisposition>()

        transport.urlSession(
            URLSession.shared,
            dataTask: task,
            didReceive: foreignResponse,
            completionHandler: { dispositionBox.value = $0 }
        )

        #expect(dispositionBox.value == .cancel)
    }

    // MARK: End-to-end transfer

    @Test func sameOriginRedirectIsFollowedAndDecoded() async throws {
        removeHandlers()
        defer { removeHandlers() }
        let png = try #require(Data(base64Encoded: Self.pngBase64))
        ImageRedirectStubURLProtocol.setHandler(forHost: Self.host) { request in
            if request.url?.path == "/avatar.png" {
                return .redirect(status: 302, location: URL(string: "https://\(Self.host)/final.png")!)
            }
            return .respond(200, png)
        }

        let loader = RemoteImageLoader(session: makeSession())
        let image = try await loader.image(for: startURL)
        let dimensions = RemoteImageLoader.decodedPixelDimensions(of: image)

        #expect(dimensions.width == 2)
        #expect(dimensions.height == 2)
    }

    @Test func crossOriginRedirectIsRefusedWithoutContactingTheTarget() async throws {
        try await assertRefusedRedirect(location: evilURL)
    }

    @Test func plaintextDowngradeRedirectIsRefused() async throws {
        try await assertRefusedRedirect(location: URL(string: "http://\(Self.host)/plain.png")!)
    }

    @Test func portChangeRedirectIsRefused() async throws {
        try await assertRefusedRedirect(location: URL(string: "https://\(Self.host):8443/port.png")!)
    }

    @Test func subdomainRedirectIsRefused() async throws {
        try await assertRefusedRedirect(location: URL(string: "https://cdn.\(Self.host)/cds.png")!)
    }

    @Test func multiHopChainIsRefusedAtTheHopLeavingTheOrigin() async throws {
        removeHandlers()
        defer { removeHandlers() }
        let png = try #require(Data(base64Encoded: Self.pngBase64))
        let trap = CaptureBox<[URLRequest]>()
        let loader = RemoteImageLoader(session: makeSession())
        ImageRedirectStubURLProtocol.setHandler(forHost: Self.host) { request in
            switch request.url?.path {
            case "/avatar.png":
                return .redirect(status: 302, location: URL(string: "https://\(Self.host)/hop.png")!)
            case "/hop.png":
                return .redirect(status: 302, location: URL(string: "https://\(Self.evilHost)/steal.png")!)
            default:
                trap.value = (trap.value ?? []) + [request]
                return .respond(200, png)
            }
        }
        ImageRedirectStubURLProtocol.setHandler(forHost: Self.evilHost) { request in
            trap.value = (trap.value ?? []) + [request]
            return .respond(200, png)
        }

        do {
            _ = try await loader.image(for: startURL)
            Issue.record("Expected the multi-hop chain to be refused")
        } catch let error as URLError {
            #expect(error.code == .badServerResponse)
        } catch {
            Issue.record("Expected URLError, got \(error)")
        }
        #expect(trap.value == nil || trap.value?.isEmpty == true,
                "Only the same-origin hop may be contacted")
        #expect(loader.cachedImageIfPresent(for: startURL) == nil)
    }

    private func assertRefusedRedirect(location: URL) async throws {
        removeHandlers()
        defer { removeHandlers() }
        let png = try #require(Data(base64Encoded: Self.pngBase64))
        let trap = CaptureBox<[URLRequest]>()
        ImageRedirectStubURLProtocol.setHandler(forHost: Self.host) { request in
            guard request.url?.path == "/avatar.png" else {
                trap.value = (trap.value ?? []) + [request]
                return .respond(200, png)
            }
            return .redirect(status: 302, location: location)
        }
        let trapHandler: ImageRedirectStubURLProtocol.Handler = { request in
            trap.value = (trap.value ?? []) + [request]
            return .respond(200, png)
        }
        ImageRedirectStubURLProtocol.setHandler(forHost: Self.evilHost, trapHandler)
        ImageRedirectStubURLProtocol.setHandler(forHost: "cdn.\(Self.host)", trapHandler)

        let loader = RemoteImageLoader(session: makeSession())
        do {
            _ = try await loader.image(for: startURL)
            Issue.record("Expected the off-origin redirect to be refused")
        } catch let error as URLError {
            #expect(error.code == .badServerResponse)
        } catch {
            Issue.record("Expected URLError, got \(error)")
        }

        #expect(trap.value == nil || trap.value?.isEmpty == true,
                "A refused redirect must never reach its target")
        #expect(loader.cachedImageIfPresent(for: startURL) == nil)
        #expect(loader.recentFailureCount == 1)
    }
}
