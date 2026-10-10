import Foundation
import Security
import Testing
@testable import CupThreadFeedback

/// Regression coverage for SEC-18 (#368): when a scoped `UserTokenStore`
/// initializes while the legacy global Keychain store is transiently
/// inaccessible (`errSecInteractionNotAllowed` before first unlock),
/// `UserTokenStore` must never treat the read failure as an empty store.
/// It must not mint and persist a fresh identity behind the unreadable
/// legacy store, nor commit `adoptionFlagKey`. An ephemeral UUID is returned
/// until the legacy store becomes accessible, preserving the user's legacy
/// identity across device unlock.
@Suite("UserTokenStore Legacy Inaccessible Reads (SEC-18)")
struct UserTokenStoreLegacyInaccessibleTests {

    final class InaccessibleStorageDouble: TokenStorage, @unchecked Sendable {
        var isInaccessible = true
        var storedValue: String?

        func load() -> String? { isInaccessible ? nil : storedValue }
        func loadResult() -> TokenLoadResult {
            isInaccessible ? .inaccessible(errSecInteractionNotAllowed) : (storedValue.map(TokenLoadResult.found) ?? .notFound)
        }
        func save(_ token: String) { storedValue = token }
        func saveConfirmed(_ token: String) -> Bool {
            guard !isInaccessible else { return false }
            storedValue = token
            return true
        }
        func delete() { storedValue = nil }
    }

    @Test func scopedStoreDoesNotForfeitAdoptionWhenLegacyGlobalStoreIsInaccessible() throws {
        let suiteName = "test.usertokenstore.inaccessible.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let appKey = "app_test_\(UUID().uuidString)"
        let tokenKey = UserTokenStore.scopedKey(for: appKey)
        let adoptionFlagKey = UserTokenStore.legacyAdoptionFlagKey(for: appKey)
        let legacyToken = "legacy_global_token_123"

        let globalStorage = InaccessibleStorageDouble()
        globalStorage.storedValue = legacyToken
        globalStorage.isInaccessible = true

        let scopedStorage = UserDefaultsTokenStorage(userDefaults: defaults, key: tokenKey)

        let store = UserTokenStore(
            storage: scopedStorage,
            legacyUserDefaults: defaults,
            legacyKey: UserTokenStore.defaultKey,
            legacyGlobalStore: globalStorage,
            adoptionDefaults: defaults,
            adoptionFlagKey: adoptionFlagKey
        )

        // 1. Initial access while legacy store is inaccessible:
        let firstToken = store.token
        #expect(!firstToken.isEmpty)
        #expect(firstToken != legacyToken)
        #expect(defaults.bool(forKey: adoptionFlagKey) == false)
        #expect(scopedStorage.load() == nil)

        // 2. Storage becomes accessible:
        globalStorage.isInaccessible = false
        let secondToken = store.token
        #expect(secondToken == legacyToken)
        #expect(defaults.bool(forKey: adoptionFlagKey) == true)
        #expect(scopedStorage.load() == legacyToken)

        // 3. Subsequent reads reuse the persisted legacy identity:
        #expect(store.token == legacyToken)
    }

    @Test func scopedStoreDoesNotFallBackToPlaintextWhenLegacyGlobalStoreIsInaccessible() throws {
        let suiteName = "test.usertokenstore.inaccessible.plaintext.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let appKey = "app_test_\(UUID().uuidString)"
        let tokenKey = UserTokenStore.scopedKey(for: appKey)
        let adoptionFlagKey = UserTokenStore.legacyAdoptionFlagKey(for: appKey)
        let legacyToken = "legacy_keychain_token_123"
        let plaintextToken = "stale_plaintext_token_456"

        defaults.set(plaintextToken, forKey: UserTokenStore.defaultKey)

        let globalStorage = InaccessibleStorageDouble()
        globalStorage.storedValue = legacyToken
        globalStorage.isInaccessible = true

        let scopedStorage = UserDefaultsTokenStorage(userDefaults: defaults, key: tokenKey)

        let store = UserTokenStore(
            storage: scopedStorage,
            legacyUserDefaults: defaults,
            legacyKey: UserTokenStore.defaultKey,
            legacyGlobalStore: globalStorage,
            adoptionDefaults: defaults,
            adoptionFlagKey: adoptionFlagKey
        )

        // 1. Initial access while legacy store is inaccessible:
        let firstToken = store.token
        #expect(!firstToken.isEmpty)
        #expect(firstToken != legacyToken)
        #expect(firstToken != plaintextToken)
        #expect(defaults.bool(forKey: adoptionFlagKey) == false)
        #expect(scopedStorage.load() == nil)

        // 2. Storage becomes accessible; keychain-held token wins over plaintext:
        globalStorage.isInaccessible = false
        let secondToken = store.token
        #expect(secondToken == legacyToken)
        #expect(defaults.bool(forKey: adoptionFlagKey) == true)
        #expect(scopedStorage.load() == legacyToken)
    }

    @Test func resetStoreAllowsMintingEvenIfLegacyGlobalStoreIsInaccessible() throws {
        let suiteName = "test.usertokenstore.inaccessible.reset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let appKey = "app_test_\(UUID().uuidString)"
        let tokenKey = UserTokenStore.scopedKey(for: appKey)
        let adoptionFlagKey = UserTokenStore.legacyAdoptionFlagKey(for: appKey)
        let legacyToken = "legacy_global_token_123"

        let globalStorage = InaccessibleStorageDouble()
        globalStorage.storedValue = legacyToken
        globalStorage.isInaccessible = false

        let scopedStorage = UserDefaultsTokenStorage(userDefaults: defaults, key: tokenKey)

        let store = UserTokenStore(
            storage: scopedStorage,
            legacyUserDefaults: defaults,
            legacyKey: UserTokenStore.defaultKey,
            legacyGlobalStore: globalStorage,
            adoptionDefaults: defaults,
            adoptionFlagKey: adoptionFlagKey
        )

        // 1. Adopt legacy identity initially:
        #expect(store.token == legacyToken)
        #expect(defaults.bool(forKey: adoptionFlagKey) == true)

        // 2. User explicitly resets the store:
        store.reset()

        // 3. Even if legacy store becomes inaccessible afterwards,
        // reset store does not get stuck and can mint a fresh token:
        globalStorage.isInaccessible = true
        let freshToken = store.token
        #expect(!freshToken.isEmpty)
        #expect(freshToken != legacyToken)
        #expect(scopedStorage.load() == freshToken)
    }
}
