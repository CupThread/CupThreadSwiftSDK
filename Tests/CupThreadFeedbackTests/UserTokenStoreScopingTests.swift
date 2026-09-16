import Foundation
import Testing
@testable import CupThreadFeedback

// MARK: - App-key-scoped token stores (issue #42)

/// An isolated, `UserDefaults`-backed scoped token store plus everything
/// needed to clean up and inspect its storage.
struct IsolatedTokenStore {
    let store: UserTokenStore
    let defaults: UserDefaults
    let tokenKey: String
    let adoptionFlagKey: String
    let legacyKeychainStandInKey: String
    let suiteName: String

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// Creates a scoped-style store backed by an isolated `UserDefaults` suite,
/// mirroring the production `UserTokenStore(appKey:)` wiring without ever
/// touching the real Keychain. The legacy global Keychain item is simulated
/// with a second defaults-backed storage.
func makeIsolatedTokenStore(
    appKey: String = "app_\(UUID().uuidString)",
    legacyGlobalToken: String? = nil,
    legacyPlaintextToken: String? = nil
) -> IsolatedTokenStore {
    let suiteName = "test.usertokenstore.scoped.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let tokenKey = UserTokenStore.scopedKey(for: appKey)
    let adoptionFlagKey = UserTokenStore.legacyAdoptionFlagKey(for: appKey)
    let legacyKeychainStandInKey = "test.legacy.keychain.global"

    if let legacyGlobalToken {
        defaults.set(legacyGlobalToken, forKey: legacyKeychainStandInKey)
    }
    if let legacyPlaintextToken {
        defaults.set(legacyPlaintextToken, forKey: UserTokenStore.defaultKey)
    }

    let store = UserTokenStore(
        storage: UserDefaultsTokenStorage(userDefaults: defaults, key: tokenKey),
        legacyUserDefaults: defaults,
        legacyKey: UserTokenStore.defaultKey,
        legacyGlobalStore: UserDefaultsTokenStorage(userDefaults: defaults, key: legacyKeychainStandInKey),
        adoptionDefaults: defaults,
        adoptionFlagKey: adoptionFlagKey
    )
    return IsolatedTokenStore(
        store: store,
        defaults: defaults,
        tokenKey: tokenKey,
        adoptionFlagKey: adoptionFlagKey,
        legacyKeychainStandInKey: legacyKeychainStandInKey,
        suiteName: suiteName
    )
}

@Suite("UserTokenStoreScoping")
struct UserTokenStoreScopingTests {

    @Test func tokensAreIsolatedPerAppKey() throws {
        let isolatedA = makeIsolatedTokenStore()
        defer { isolatedA.cleanup() }
        let isolatedB = makeIsolatedTokenStore()
        defer { isolatedB.cleanup() }

        let tokenA = isolatedA.store.token
        let tokenB = isolatedB.store.token

        #expect(tokenA != tokenB)
        #expect(UUID(uuidString: tokenA) != nil)
        #expect(UUID(uuidString: tokenB) != nil)

        // Each identity persists under its own key and is stable across reads.
        #expect(isolatedA.store.token == tokenA)
        #expect(isolatedB.store.token == tokenB)
        #expect(isolatedA.defaults.string(forKey: isolatedA.tokenKey) == tokenA)
        #expect(isolatedB.defaults.string(forKey: isolatedB.tokenKey) == tokenB)
    }

    @Test func resetMintsFreshPersistedIdentity() throws {
        let isolated = makeIsolatedTokenStore()
        defer { isolated.cleanup() }

        let original = isolated.store.token
        isolated.store.reset()

        let fresh = isolated.store.token
        #expect(fresh != original)
        #expect(UUID(uuidString: fresh) != nil)
        #expect(isolated.defaults.string(forKey: isolated.tokenKey) == fresh)

        // A second store instance reading the same key keeps the fresh identity.
        let reloaded = UserTokenStore(
            storage: UserDefaultsTokenStorage(userDefaults: isolated.defaults, key: isolated.tokenKey)
        )
        #expect(reloaded.token == fresh)
    }

    @Test func firstScopedReadAdoptsKeychainHeldLegacyIdentity() throws {
        let legacy = UUID().uuidString
        let isolated = makeIsolatedTokenStore(legacyGlobalToken: legacy)
        defer { isolated.cleanup() }

        #expect(isolated.store.token == legacy)
        // Adopted identity is persisted under the scoped key.
        #expect(isolated.defaults.string(forKey: isolated.tokenKey) == legacy)
    }

    @Test func firstScopedReadAdoptsPlaintextLegacyIdentityWhenKeychainEmpty() throws {
        let legacy = UUID().uuidString
        let isolated = makeIsolatedTokenStore(legacyPlaintextToken: legacy)
        defer { isolated.cleanup() }

        #expect(isolated.store.token == legacy)
        #expect(isolated.defaults.string(forKey: isolated.tokenKey) == legacy)
    }

    @Test func keychainHeldLegacyIdentityWinsOverPlaintext() throws {
        let keychainToken = UUID().uuidString
        let plaintextToken = UUID().uuidString
        let isolated = makeIsolatedTokenStore(
            legacyGlobalToken: keychainToken,
            legacyPlaintextToken: plaintextToken
        )
        defer { isolated.cleanup() }

        #expect(isolated.store.token == keychainToken)
    }

    @Test func secondAppKeyAlsoInheritsLegacyIdentityIndependently() throws {
        let legacy = UUID().uuidString
        let isolatedA = makeIsolatedTokenStore(appKey: "app_shared_legacy", legacyGlobalToken: legacy)
        defer { isolatedA.cleanup() }
        let isolatedB = makeIsolatedTokenStore(appKey: "app_other_legacy", legacyGlobalToken: legacy)
        defer { isolatedB.cleanup() }

        #expect(isolatedA.store.token == legacy)
        #expect(isolatedB.store.token == legacy)

        // The two stores then persist the inherited identity independently.
        #expect(isolatedA.tokenKey != isolatedB.tokenKey)
        #expect(isolatedA.defaults.string(forKey: isolatedA.tokenKey) == legacy)
        #expect(isolatedB.defaults.string(forKey: isolatedB.tokenKey) == legacy)
    }

    @Test func legacyAdoptionIsOneShotEvenWithoutLegacyIdentity() throws {
        let isolated = makeIsolatedTokenStore()
        defer { isolated.cleanup() }

        // First access mints fresh and flags adoption as done.
        let minted = isolated.store.token
        #expect(isolated.defaults.bool(forKey: isolated.adoptionFlagKey))

        // A global identity appearing afterwards never clobbers the minted one.
        let lateGlobal = UUID().uuidString
        isolated.defaults.set(lateGlobal, forKey: isolated.legacyKeychainStandInKey)
        #expect(isolated.store.token == minted)
        #expect(isolated.store.token != lateGlobal)
    }

    @Test func resetPreventsLegacyReinheritance() throws {
        let legacy = UUID().uuidString
        let isolated = makeIsolatedTokenStore(legacyGlobalToken: legacy)
        defer { isolated.cleanup() }

        #expect(isolated.store.token == legacy)
        isolated.store.reset()

        // The rotated/deleted identity must not be resurrected from the
        // still-present global source.
        let fresh = isolated.store.token
        #expect(fresh != legacy)
        #expect(isolated.defaults.string(forKey: isolated.tokenKey) == fresh)
    }

    @Test func scopedLegacyAdoptionKeepsGlobalSourcesIntact() throws {
        let legacy = UUID().uuidString
        let isolated = makeIsolatedTokenStore(legacyGlobalToken: legacy, legacyPlaintextToken: legacy)
        defer { isolated.cleanup() }

        _ = isolated.store.token

        // Scoped stores copy but never delete the global sources, so sibling
        // app keys and `.shared` can still adopt the legacy identity.
        #expect(isolated.defaults.string(forKey: isolated.legacyKeychainStandInKey) == legacy)
        #expect(isolated.defaults.string(forKey: UserTokenStore.defaultKey) == legacy)
    }

    @Test func concurrentFirstAccessOnScopedStoreResolvesIdenticalToken() async throws {
        let isolated = makeIsolatedTokenStore()
        defer { isolated.cleanup() }
        let store = isolated.store

        let concurrency = 64
        let tokens = await withTaskGroup(of: String.self) { group in
            for _ in 0..<concurrency {
                group.addTask {
                    store.token
                }
            }

            var collected: [String] = []
            for await token in group {
                collected.append(token)
            }
            return collected
        }

        #expect(tokens.count == concurrency)
        let uniqueTokens = Set(tokens)
        #expect(uniqueTokens.count == 1)
    }

    @Test func clientsWithDifferentAppKeysGetDistinctScopedStores() {
        let clientA = makeClient(appKey: "app_alpha")
        let clientB = makeClient(appKey: "app_beta")

        // Construction only wires storage handles (no token reads, no real
        // Keychain I/O): each client owns its own app-key-scoped store.
        #expect(clientA.tokenStore !== clientB.tokenStore)
    }
}
