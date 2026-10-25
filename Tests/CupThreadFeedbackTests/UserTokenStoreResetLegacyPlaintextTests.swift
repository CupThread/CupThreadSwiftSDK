import Foundation
import Security
import Testing
@testable import CupThreadFeedback

/// Regression coverage for issue #584: a confirmed `reset()` on the
/// `.shared`-shaped store (no adoption flag, so it owns the legacy
/// `UserDefaults` plaintext) must also discard that plaintext. Left behind, a
/// reset that runs before the first `token` read of a legacy-upgraded install
/// reports success while the next read re-adopts — and re-persists — the very
/// identity the reset removed.
@Suite("UserTokenStore Reset Legacy Plaintext (issue #584)")
struct UserTokenStoreResetLegacyPlaintextTests {

    /// A `.shared`-shaped store on an install upgraded across the
    /// pre-Keychain boundary: the plaintext token still sits in defaults, the
    /// backing store holds nothing, and migration has not run yet.
    private struct LegacyUpgradedInstall {
        let store: UserTokenStore
        let storage: any TokenStorage
        let defaults: UserDefaults
        let legacyKey: String
        let legacyToken: String
        let suiteName: String

        var plaintext: String? {
            defaults.string(forKey: legacyKey)
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    /// Mirrors `UserTokenStore()`: no adoption flag, so the store owns (and is
    /// responsible for purging) the legacy plaintext. The backing storage
    /// defaults to an empty defaults-backed stand-in whose deletions always
    /// confirm, like a Keychain answering `errSecItemNotFound`.
    private func makeLegacyUpgradedInstall(
        storage: (any TokenStorage)? = nil
    ) -> LegacyUpgradedInstall {
        let suiteName = "test.usertokenstore.reset584.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let legacyKey = "test.reset584.legacy.plaintext"
        let legacyToken = UUID().uuidString.lowercased()
        defaults.set(legacyToken, forKey: legacyKey)

        let backing = storage ?? UserDefaultsTokenStorage(userDefaults: defaults, key: "test.reset584.store")
        let store = UserTokenStore(
            storage: backing,
            legacyUserDefaults: defaults,
            legacyKey: legacyKey
        )
        return LegacyUpgradedInstall(
            store: store,
            storage: backing,
            defaults: defaults,
            legacyKey: legacyKey,
            legacyToken: legacyToken,
            suiteName: suiteName
        )
    }

    @Test func confirmedResetBeforeFirstReadForfeitsTheOwnedPlaintext() {
        let install = makeLegacyUpgradedInstall()
        defer { install.cleanup() }

        // The backing store is empty, so the deletion is verifiably confirmed.
        #expect(install.store.reset())

        // The plaintext the reset must not leave behind is gone ...
        #expect(install.plaintext == nil)

        // ... so the next read cannot re-adopt the removed identity: it mints
        // and persists a fresh one, exactly as the reset contract promises.
        let fresh = install.store.token
        #expect(UUID(uuidString: fresh) != nil)
        #expect(fresh != install.legacyToken)
        #expect(install.storage.load() == fresh)
        #expect(install.store.token == fresh)
    }

    @Test func repeatedConfirmedResetsStayConfirmedAndNeverReadopt() {
        let install = makeLegacyUpgradedInstall()
        defer { install.cleanup() }

        // Nothing is stored either time: both deletions confirm, and the
        // second one simply finds no plaintext left to purge.
        #expect(install.store.reset())
        #expect(install.store.reset())
        #expect(install.plaintext == nil)

        // Resetting across a minted identity keeps rotating forward; the
        // legacy identity never resurfaces.
        let first = install.store.token
        #expect(install.store.reset())
        let second = install.store.token
        #expect(first != install.legacyToken)
        #expect(second != install.legacyToken)
        #expect(second != first)
        #expect(install.plaintext == nil)
        #expect(install.storage.load() == second)
    }

    @Test func unconfirmedResetKeepsTheOwnedPlaintextAndTheIdentity() {
        let install = makeLegacyUpgradedInstall(storage: RefusingDeleteTokenStorage())
        defer { install.cleanup() }

        // The deletion could not be confirmed, so nothing may be destroyed:
        // the plaintext stays exactly where it was.
        #expect(!install.store.reset())
        #expect(install.plaintext == install.legacyToken)

        // The unresolved run still resolves to the legacy identity on the
        // next read — the failed reset lost nothing.
        #expect(install.store.token == install.legacyToken)
        #expect(install.storage.load() == install.legacyToken)
    }

    @Test func scopedStoreResetLeavesTheGlobalPlaintextToItsOwner() {
        let legacy = UUID().uuidString.lowercased()
        let isolated = makeIsolatedTokenStore(legacyPlaintextToken: legacy)
        defer { isolated.cleanup() }

        // A scoped store copies the global plaintext on first read but never
        // deletes it: the plaintext belongs to `UserTokenStore.shared`.
        #expect(isolated.store.token == legacy)
        #expect(isolated.defaults.string(forKey: UserTokenStore.defaultKey) == legacy)

        // Its reset is flag-protected, not plaintext-protected: the global
        // plaintext survives, and the adoption flag alone keeps the removed
        // identity from being re-inherited.
        #expect(isolated.store.reset())
        #expect(isolated.defaults.string(forKey: UserTokenStore.defaultKey) == legacy)

        let fresh = isolated.store.token
        #expect(fresh != legacy)
        #expect(isolated.defaults.string(forKey: UserTokenStore.defaultKey) == legacy)
    }

    @Test func confirmedResetOnEmptyKeychainPurgesPlaintextBeforeTheFirstRead() {
        // The production trigger end to end: an empty Keychain answers
        // `errSecItemNotFound` to both the read and the delete, which
        // `KeychainTokenStorage.deleteConfirmed()` reports as a confirmed
        // (verifiably absent) deletion.
        let added = AddedTokenRecorder()
        let storage = KeychainTokenStorage(
            service: "com.cupthread.test.reset584.\(UUID().uuidString)",
            account: "account.\(UUID().uuidString)",
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            addItem: { attributes in
                added.record(attributes)
                return errSecSuccess
            },
            updateItem: { _, _ in errSecSuccess },
            copyItem: { _, _ in errSecItemNotFound },
            deleteItem: { _ in errSecItemNotFound }
        )
        let install = makeLegacyUpgradedInstall(storage: storage)
        defer { install.cleanup() }

        #expect(install.store.reset())
        #expect(install.plaintext == nil)

        // The removed identity is never written back into the Keychain; only
        // the freshly minted one is.
        let fresh = install.store.token
        #expect(fresh != install.legacyToken)
        #expect(added.tokens == [fresh])
    }
}

/// Storage double modelling a Keychain whose `SecItemDelete` keeps failing
/// (e.g. `errSecInteractionNotAllowed`): reads and confirmed writes behave
/// normally, but no deletion is ever confirmed and the item stays in place.
private final class RefusingDeleteTokenStorage: TokenStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    func load() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func save(_ token: String) {
        _ = saveConfirmed(token)
    }

    @discardableResult
    func saveConfirmed(_ token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        stored = token
        return true
    }

    func delete() {
        _ = deleteConfirmed()
    }

    @discardableResult
    func deleteConfirmed() -> Bool {
        false
    }
}

/// Thread-safe record of every token value handed to the scripted
/// `SecItemAdd`, in order.
private final class AddedTokenRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ attributes: CFDictionary) {
        let dictionary = attributes as NSDictionary
        guard let data = dictionary[kSecValueData as String] as? Data,
              let token = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        recorded.append(token)
    }

    var tokens: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
