import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - eraseMyData(store:) local-cleanup confirmation (SEC-29, #496)

@Suite("DataErasureLocalCleanup", .serialized)
struct DataErasureLocalCleanupTests {
    static let apiHost = "apisync-erase-cleanup.example.com"

    func makeIsolatedCleanupState(appKey: String = "app_\(UUID().uuidString)")
        -> (state: DataErasureCleanupState, cleanup: () -> Void) {
        let suiteName = "test.erasurecleanup.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (
            DataErasureCleanupState(appKey: appKey, defaults: defaults),
            { defaults.removePersistentDomain(forName: suiteName) }
        )
    }

    func makeIsolatedSubscriptionStore(item: ScriptedKeychainItem, appKey: String)
        -> ChangelogSubscriptionStore {
        ChangelogSubscriptionStore(
            appKey: appKey,
            storage: makeScriptedKeychainStorage(item: item),
            legacyUserDefaults: nil
        )
    }

    @Test func eraseFlagsPendingCleanupWhenSubscriptionDeleteFails() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            let token = request.value(forHTTPHeaderField: "X-User-Token")
            return (makeHTTPResponse(), try encodeJSON(["erased": true, "endUserId": token]))
        }

        let item = ScriptedKeychainItem()
        let subscription = makeIsolatedSubscriptionStore(item: item, appKey: "app_erase_sub_fail")
        subscription.persist(record: ChangelogSubscriptionRecord(email: "user@example.com", state: .confirmed))

        let isolated = makeIsolatedTokenStore()
        defer { isolated.cleanup() }
        let cleanup = makeIsolatedCleanupState()
        defer { cleanup.cleanup() }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!, tokenStore: isolated.store)
        let result = try await client.eraseMyData(
            store: isolated.store,
            subscriptionStore: subscription,
            cleanupState: cleanup.state
        )

        // The erasure itself succeeded, but the subscriber email could not be
        // confirmed deleted: the result must say so instead of a silent success.
        #expect(result.erased == true)
        #expect(result.localCleanupPending == true)
        #expect(cleanup.state.isPending == true)
        #expect(subscription.subscribedEmail() == "user@example.com")
    }

    @Test func eraseReplayRetriesPendingCleanupOnceKeychainIsAvailable() async throws {
        let eraseCount = CaptureBox<Int>()
        MockURLProtocol.setHandler(forHost: Self.apiHost) { request in
            eraseCount.value = (eraseCount.value ?? 0) + 1
            let token = request.value(forHTTPHeaderField: "X-User-Token")
            if eraseCount.value == 1 {
                return (makeHTTPResponse(), try encodeJSON(["erased": true, "endUserId": token]))
            }
            // The idempotent replay: the profile is already gone. The
            // genuine no-match answer carries the documented envelope
            // (#540) — a bare 404 means infrastructure, not resource state.
            return (makeHTTPResponse(status: 404), try encodeJSON(["erased": false, "error": "No profile found"]))
        }

        let item = ScriptedKeychainItem()
        let subscription = makeIsolatedSubscriptionStore(item: item, appKey: "app_erase_replay")
        subscription.persist(record: ChangelogSubscriptionRecord(email: "user@example.com", state: .confirmed))

        let isolated = makeIsolatedTokenStore()
        defer { isolated.cleanup() }
        let cleanup = makeIsolatedCleanupState()
        defer { cleanup.cleanup() }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!, tokenStore: isolated.store)
        let first = try await client.eraseMyData(
            store: isolated.store,
            subscriptionStore: subscription,
            cleanupState: cleanup.state
        )
        #expect(first.localCleanupPending == true)

        // The Keychain becomes available; the `erased: false` replay must
        // still finish the outstanding cleanup instead of skipping it.
        item.failDeletion = false
        let second = try await client.eraseMyData(
            store: isolated.store,
            subscriptionStore: subscription,
            cleanupState: cleanup.state
        )
        #expect(second.erased == false)
        #expect(second.localCleanupPending == false)
        #expect(subscription.subscribedEmail() == nil)
        #expect(cleanup.state.isPending == false)
    }

    @Test func eraseFlagsPendingWhenIdentityResetFailsAndReplayDropsToken() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(), try encodeJSON(["erased": true]))
        }

        let item = ScriptedKeychainItem()
        let identityStorage = makeScriptedKeychainStorage(item: item)
        let store = UserTokenStore(storage: identityStorage)
        let identity = store.token

        let cleanup = makeIsolatedCleanupState()
        defer { cleanup.cleanup() }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!, tokenStore: store)
        let first = try await client.eraseMyData(
            store: store,
            subscriptionStore: nil,
            cleanupState: cleanup.state
        )
        // A failing identity deletion must not surface as a clean success.
        #expect(first.erased == true)
        #expect(first.localCleanupPending == true)
        #expect(cleanup.state.isPending == true)
        #expect(store.token == identity)

        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 404), try encodeJSON(["erased": false, "error": "No profile found"]))
        }
        item.failDeletion = false
        let second = try await client.eraseMyData(
            store: store,
            subscriptionStore: nil,
            cleanupState: cleanup.state
        )
        #expect(second.localCleanupPending == false)
        #expect(cleanup.state.isPending == false)
        #expect(store.token != identity)
    }

    @Test func eraseReplayKeepsCleanStoresWhenNoPendingCleanup() async throws {
        MockURLProtocol.setHandler(forHost: Self.apiHost) { _ in
            (makeHTTPResponse(status: 404), try encodeJSON(["erased": false, "error": "No profile found"]))
        }

        let isolated = makeIsolatedTokenStore()
        defer { isolated.cleanup() }
        let identity = isolated.store.token
        let cleanup = makeIsolatedCleanupState()
        defer { cleanup.cleanup() }

        let client = makeClient(baseURL: URL(string: "https://\(Self.apiHost)")!, tokenStore: isolated.store)
        let result = try await client.eraseMyData(
            store: isolated.store,
            subscriptionStore: nil,
            cleanupState: cleanup.state
        )

        // Without an outstanding cleanup, the `erased: false` semantics are
        // unchanged: the identity survives and no marker is written.
        #expect(result.erased == false)
        #expect(result.localCleanupPending == false)
        #expect(isolated.store.token == identity)
        #expect(cleanup.state.isPending == false)
    }

    @Test func cleanupStateKeysAreNormalizedPerAppKey() {
        let suiteName = "test.erasurecleanup.keys.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let padded = DataErasureCleanupState(appKey: "  app_erase_keys \n", defaults: defaults)
        let trimmed = DataErasureCleanupState(appKey: "app_erase_keys", defaults: defaults)
        #expect(padded.key == trimmed.key)

        padded.setPending(true)
        #expect(trimmed.isPending == true)
        trimmed.setPending(false)
        #expect(padded.isPending == false)
    }
}
