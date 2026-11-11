import Foundation
import Testing
@testable import CupThreadFeedback

// All network tests share the static MockURLProtocol handler, so they run
// serialized. This suite uses its own base host so it can run in parallel.
@Suite("ResourceProtection", .serialized)
@MainActor
struct ResourceProtectionTests {
    private static let host = "resource-protection.example.com"

    private final class RequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var count = 0

        func record() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }
    }

    private func makeLoader(appKey: String) -> SdkConfigLoader {
        let suiteName = "\(appKey)-\(UUID().uuidString)"
        let cache = SdkConfigCache(
            appKey: appKey,
            storage: UserDefaultsConfigStorage(userDefaults: UserDefaults(suiteName: suiteName)!)
        )
        let store = AppConfigStore(lastGood: cache)
        return SdkConfigLoader(
            client: makeClient(
                baseURL: URL(string: "https://\(Self.host)")!,
                appKey: appKey,
                configStore: store
            ),
            store: store
        )
    }

    private func makeHostClient(
        appKey: String,
        store: AppConfigStore
    ) -> FeedbackClient {
        CupThreadFeedbackTests.makeClient(
            baseURL: URL(string: "https://\(Self.host)")!,
            appKey: appKey,
            configStore: store
        )
    }

    @Test func fetchResourceProtectionHitsEndpointAndDecodesSignal() async throws {
        let capture = CaptureBox<URL>()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            capture.value = request.url
            return (makeHTTPResponse(), try encodeJSON(["optionalImagesDisabled": true]))
        }

        let state = try await makeClient(
            baseURL: URL(string: "https://\(Self.host)")!
        ).fetchResourceProtection()

        let url = try #require(capture.value)
        #expect(url.path == "/api/v1/public/resource-protection")
        #expect(state == ResourceProtectionStatus(optionalImagesDisabled: true))
    }

    @Test func protectionResolvesBeforeConfigBecomesReady() async throws {
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            if request.url?.path == "/api/v1/public/resource-protection" {
                return (
                    makeHTTPResponse(),
                    try encodeJSON(["optionalImagesDisabled": true])
                )
            }
            return (makeHTTPResponse(), try encodeJSON(makeConfigJSON()))
        }

        let loader = makeLoader(appKey: "app_protection_ready")
        await loader.load()

        guard case .ready = loader.status else {
            Issue.record("Expected ready, got \(loader.status)")
            return
        }
        #expect(loader.optionalImagesDisabled == true)
    }

    @Test func missingProtectionEndpointClearsSignalOnRefresh() async throws {
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            if request.url?.path == "/api/v1/public/resource-protection" {
                return (
                    makeHTTPResponse(),
                    try encodeJSON(["optionalImagesDisabled": true])
                )
            }
            return (makeHTTPResponse(), try encodeJSON(makeConfigJSON()))
        }

        let loader = makeLoader(appKey: "app_protection_missing")
        await loader.load()
        #expect(loader.optionalImagesDisabled == true)

        MockURLProtocol.setHandler(forHost: Self.host) { request in
            if request.url?.path == "/api/v1/public/resource-protection" {
                return (
                    makeHTTPResponse(status: 404),
                    try encodeJSON(["error": "Not Found"])
                )
            }
            return (makeHTTPResponse(), try encodeJSON(makeConfigJSON()))
        }

        await loader.refresh()

        #expect(loader.optionalImagesDisabled == false)
    }

    @Test func warmConfigLoadDoesNotRefetchProtection() async throws {
        let counter = RequestCounter()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            if request.url?.path == "/api/v1/public/resource-protection" {
                counter.record()
                return (
                    makeHTTPResponse(),
                    try encodeJSON(["optionalImagesDisabled": true])
                )
            }
            return (makeHTTPResponse(), try encodeJSON(makeConfigJSON()))
        }

        let loader = makeLoader(appKey: "app_protection_ttl")
        await loader.load()
        await loader.load()

        #expect(loader.optionalImagesDisabled == true)
        #expect(counter.count == 1)
    }

    @Test func cachedAppConfigCannotWarmConfigWithoutProtection() async throws {
        let protectionCounter = RequestCounter()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            if request.url?.path == "/api/v1/public/resource-protection" {
                protectionCounter.record()
                return (
                    makeHTTPResponse(),
                    try encodeJSON(["optionalImagesDisabled": true])
                )
            }
            return (makeHTTPResponse(), try encodeJSON(makeConfigJSON()))
        }

        let suiteName = "app_protection_cached_config-\(UUID().uuidString)"
        let cache = SdkConfigCache(
            appKey: "app_protection_cached_config",
            storage: UserDefaultsConfigStorage(userDefaults: UserDefaults(suiteName: suiteName)!)
        )
        let store = AppConfigStore(lastGood: cache)
        let client = makeHostClient(appKey: "app_protection_cached_config", store: store)
        _ = try await client.cachedAppConfig()

        let loader = SdkConfigLoader(client: client, store: store)
        guard case .loading = loader.status else {
            Issue.record("Warm config without protection must stay loading")
            return
        }
        #expect(loader.optionalImagesDisabled == false)

        await loader.load()

        guard case .ready = loader.status else {
            Issue.record("Expected ready after protection resolved")
            return
        }
        #expect(loader.optionalImagesDisabled == true)
        #expect(protectionCounter.count == 1)
    }

    @Test func secondLoaderInheritsResolvedProtection() async throws {
        let protectionCounter = RequestCounter()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            if request.url?.path == "/api/v1/public/resource-protection" {
                protectionCounter.record()
                return (
                    makeHTTPResponse(),
                    try encodeJSON(["optionalImagesDisabled": true])
                )
            }
            return (makeHTTPResponse(), try encodeJSON(makeConfigJSON()))
        }

        let appKey = "app_protection_two_loaders"
        let suiteName = "\(appKey)-\(UUID().uuidString)"
        let cache = SdkConfigCache(
            appKey: appKey,
            storage: UserDefaultsConfigStorage(userDefaults: UserDefaults(suiteName: suiteName)!)
        )
        let sharedStore = AppConfigStore(lastGood: cache)
        let firstLoader = SdkConfigLoader(
            client: makeHostClient(appKey: appKey, store: sharedStore),
            store: sharedStore
        )
        await firstLoader.load()
        #expect(firstLoader.optionalImagesDisabled == true)

        let secondLoader = SdkConfigLoader(
            client: makeHostClient(appKey: appKey, store: sharedStore),
            store: sharedStore
        )

        guard case .ready = secondLoader.status else {
            Issue.record("Second loader must inherit the resolved client state")
            return
        }
        #expect(secondLoader.optionalImagesDisabled == true)

        await secondLoader.load()
        #expect(protectionCounter.count == 1)
    }

    @Test func standaloneEntryViewsResolveSharedProtection() async throws {
        let protectionCounter = RequestCounter()
        MockURLProtocol.setHandler(forHost: Self.host) { request in
            guard request.url?.path == "/api/v1/public/resource-protection" else {
                return (makeHTTPResponse(), try encodeJSON(makeConfigJSON()))
            }
            protectionCounter.record()
            return (
                makeHTTPResponse(),
                try encodeJSON(["optionalImagesDisabled": true])
            )
        }

        let suiteName = "app_standalone_protection-\(UUID().uuidString)"
        let cache = SdkConfigCache(
            appKey: "app_standalone_protection",
            storage: UserDefaultsConfigStorage(userDefaults: UserDefaults(suiteName: suiteName)!)
        )
        let store = AppConfigStore(lastGood: cache)
        let client = makeHostClient(appKey: "app_standalone_protection", store: store)
        let commentsView = CommentsView(
            client: client,
            userToken: "token_123",
            featureRequestId: "fr_1",
            featureRequestTitle: "Title"
        )
        let profileView = UserProfileView(client: client, userId: "u_1")

        #expect(
            viewTreeContains(commentsView.body, OptionalImageProtectionModifier.self),
            "CommentsView must resolve protection when presented standalone"
        )
        #expect(
            viewTreeContains(profileView.body, OptionalImageProtectionModifier.self),
            "UserProfileView must resolve protection when presented standalone"
        )

        let firstObserver = ResourceProtectionLoader(client: client)
        #expect(firstObserver.optionalImagesDisabled == true, "A cold standalone view must fail closed")
        await firstObserver.resolve()
        #expect(firstObserver.optionalImagesDisabled == true)

        let secondObserver = ResourceProtectionLoader(client: client)
        #expect(secondObserver.optionalImagesDisabled == true)
        #expect(protectionCounter.count == 1)
    }

    @Test func protectedOptionalImagesResolveToLocalPlaceholder() {
        let protectedURL = AvatarView(
            url: "https://cdn.example.com/avatar.png",
            optionalImagesDisabledOverride: true
        ).resolvedURL
        let restoredURL = AvatarView(
            url: "https://cdn.example.com/avatar.png",
            optionalImagesDisabledOverride: false
        ).resolvedURL

        #expect(protectedURL == nil)
        #expect(restoredURL == URL(string: "https://cdn.example.com/avatar.png"))
    }

    @Test func transientProtectionFailureDoesNotCreateAvailabilityClaim() async throws {
        MockURLProtocol.setHandler(forHost: Self.host) { _ in
            (makeHTTPResponse(status: 503), Data("unavailable".utf8))
        }
        let suiteName = "app_protection_failure-\(UUID().uuidString)"
        let cache = SdkConfigCache(
            appKey: "app_protection_failure",
            storage: UserDefaultsConfigStorage(userDefaults: UserDefaults(suiteName: suiteName)!)
        )
        let store = AppConfigStore(lastGood: cache)
        let loader = SdkConfigLoader(
            client: makeHostClient(appKey: "app_protection_failure", store: store),
            store: store
        )
        await loader.load()

        guard case .failed = loader.status else {
            Issue.record("Expected failed without creating an availability claim")
            return
        }
        #expect(loader.optionalImagesDisabled == false)

        let transientClient = makeHostClient(
            appKey: "app_protection_failure",
            store: store
        )
        let observer = ResourceProtectionLoader(client: transientClient)
        #expect(observer.optionalImagesDisabled == true)
        await observer.resolve()
        #expect(observer.optionalImagesDisabled == false)
    }

}
