import Foundation
import Security
@testable import CupThreadFeedback

// MARK: - Shared test helpers

/// URLProtocol subclass that intercepts all requests and routes them to a per-host handler.
///
/// Suites marked `.serialized` only serialize their own tests, so two suites can run in
/// parallel. Keying handlers by request host (each suite uses its own base URL) keeps
/// parallel suites from stomping each other's handlers.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let defaultHost = "test.example.com"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    /// Handler for requests to the default mock host (https://test.example.com).
    nonisolated(unsafe) static var requestHandler: Handler? {
        get { handler(forHost: defaultHost) }
        set { setHandler(forHost: defaultHost, newValue) }
    }

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
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Thread-safe box for capturing Sendable values from URLProtocol handler closures.
final class CaptureBox<T: Sendable>: @unchecked Sendable {
    var value: T?
}

/// Create a URLSession backed by MockURLProtocol.
func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

/// Create a FeedbackClient wired to the mock session.
func makeClient(
    baseURL: URL = URL(string: "https://test.example.com")!,
    appKey: String = "app_testkey123456",
    platform: FeedbackPlatform = .ios,
    overlayPresenter: (any ChangelogOverlayPresenter)? = nil,
    signingSecret: String? = nil,
    searchThrottle: SearchRequestThrottle? = nil,
    tokenStore: UserTokenStore? = nil,
    configStore: AppConfigStore? = nil,
    serverClock: ServerClock? = nil,
    authenticationProvider: (@Sendable () async -> String?)? = nil,
    userAttributesSigner: (@Sendable (UserAttributesSigningRequest) async throws -> UserAttributesSignature?)? = nil
) -> FeedbackClient {
    let config = FeedbackClientConfiguration(
        baseURL: baseURL,
        appKey: appKey,
        defaultPlatform: platform,
        signingSecret: signingSecret
    )
    return FeedbackClient(
        configuration: config,
        session: makeMockSession(),
        overlayPresenter: overlayPresenter,
        searchThrottle: searchThrottle,
        tokenStore: tokenStore,
        configStore: configStore,
        serverClock: serverClock,
        authenticationProvider: authenticationProvider,
        userAttributesSigner: userAttributesSigner
    )
}

/// Make an HTTPURLResponse.
func makeHTTPResponse(
    status: Int = 200,
    url: URL = URL(string: "https://test.example.com")!,
    headers: [String: String]? = nil
) -> HTTPURLResponse {
    var allHeaders = ["Content-Type": "application/json"]
    if let headers {
        allHeaders.merge(headers) { _, new in new }
    }
    return HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: nil,
        headerFields: allHeaders
    )!
}

/// Encode a dictionary to Data.
func encodeJSON(_ dict: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: dict)
}

/// Whether a SwiftUI view value's reflected tree contains `target`.
///
/// View-level tests inspect a rendered body without a hosting hierarchy;
/// `Mirror` walks the nested view values the layout branches produce.
func viewTreeContains(_ node: Any, _ target: Any.Type) -> Bool {
    if type(of: node) == target { return true }
    for child in Mirror(reflecting: node).children
    where viewTreeContains(child.value, target) {
        return true
    }
    return false
}

/// Read httpBody from an intercepted request (handles both body and stream).
func bodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    var data = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
    defer { buffer.deallocate() }
    stream.open()
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: 4096)
        guard read > 0 else { break }
        data.append(buffer, count: read)
    }
    stream.close()
    return data
}

/// Parse captured Data as a [String: Any] dictionary.
func parseJSONDict(_ data: Data) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

/// Make default config JSON dictionary for tests.
func makeConfigJSON() -> [String: Any] {
    [
        "appId": "app-1",
        "appKey": "app_testkey123456",
        "slug": "demo-app",
        "workspaceSlug": "demo-workspace",
        "name": "Demo App",
        "storeUrl": NSNull(),
        "storeKind": NSNull(),
        "appStoreUrl": NSNull(),
        "googlePlayUrl": NSNull(),
        "iconUrl": "https://example.com/icon.png",
        "allowPublic": true,
        "allowedPlatforms": ["ios", "macos"],
        "maxAttachmentBytes": 20_000_000,
        "allowAnonymousRoadmap": true,
        "allowAnonymousVote": false,
        "allowAnonymousFeedback": true
    ]
}

// MARK: - Scripted-Keychain helper (SEC-29 delete-confirmation coverage)

/// Mutable backing item for `makeScriptedKeychainStorage`. Tests flip
/// `failDeletion` to simulate a locked Keychain becoming readable again.
final class ScriptedKeychainItem: @unchecked Sendable {
    var data: Data?
    /// While `true`, `SecItemDelete` reports `errSecInteractionNotAllowed`.
    var failDeletion = true
}

/// A `KeychainTokenStorage` whose Security-framework outcomes are scripted
/// in memory: confirmed writes capture into `item`, reads serve `item.data`,
/// and deletion fails with `errSecInteractionNotAllowed` until
/// `item.failDeletion` is cleared. Never touches the real Keychain.
func makeScriptedKeychainStorage(item: ScriptedKeychainItem) -> KeychainTokenStorage {
    KeychainTokenStorage(
        service: "com.cupthread.test.scriptedDelete",
        account: "scripted.\(UUID().uuidString)",
        accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        addItem: { attributes in
            item.data = (attributes as NSDictionary)[kSecValueData] as? Data
            return errSecSuccess
        },
        updateItem: { _, attributes in
            item.data = (attributes as NSDictionary)[kSecValueData] as? Data
            return errSecSuccess
        },
        copyItem: { _, result in
            guard let data = item.data else { return errSecItemNotFound }
            result?.pointee = data as CFTypeRef
            return errSecSuccess
        },
        deleteItem: { _ in
            if item.failDeletion { return errSecInteractionNotAllowed }
            item.data = nil
            return errSecSuccess
        }
    )
}

// MARK: - Data-protection keychain availability (SEC-33)

/// Whether SecItem operations targeting the data-protection keychain succeed
/// from this process (SEC-33).
///
/// On macOS the data-protection keychain is only available to code-signed,
/// provisioned processes (TN3137): every operation from an unsigned or
/// unprovisioned caller — including SwiftPM's `swift test` host — fails with
/// `errSecMissingEntitlement`. iOS, tvOS, and visionOS have no file-based
/// keychain, so the answer is unconditionally `true` there. Real-Keychain
/// round-trip tests enable themselves with `.enabled(if:)` on this value so
/// they run where the keychain is writable and skip (never fail, and never
/// silently no-op) where it is not.
enum DataProtectionKeychainProbe {
    /// Lazily probed once per process; the probe writes and deletes a
    /// uniquely named item through the same attribute set
    /// `KeychainTokenStorage` uses.
    static let isWritable: Bool = probe()

    private static func probe() -> Bool {
        #if os(macOS)
        let service = "com.cupthread.test.dpProbe.\(UUID().uuidString)"
        let addAttributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "dp-probe",
            kSecValueData as String: Data("probe".utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true
        ]
        let status = SecItemAdd(addAttributes as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            return false
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "dp-probe",
            kSecUseDataProtectionKeychain as String: true
        ]
        // The round-trip tests gated on this probe also delete, so the
        // probe is only "writable" when the cleanup delete is confirmed —
        // otherwise the uniquely named probe item would leak and the
        // enabled tests would fail on a host that cannot complete the
        // cycle.
        return SecItemDelete(query as CFDictionary) == errSecSuccess
        #else
        return true
        #endif
    }
}
