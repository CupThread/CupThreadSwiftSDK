import Foundation
import Security
import Testing
@testable import CupThreadFeedback

/// Regression coverage for SEC-28 (#443): `KeychainTokenStorage.delete` must provide
/// an injected seam and confirm whether deletion succeeded, preventing silent failures
/// and identity retention after profile erasure.
@Suite("KeychainTokenStorage Deletion Tests (SEC-28)")
struct KeychainTokenStorageDeletionTests {

    private final class QueryRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var query: [String: Any]?

        func record(_ query: [String: Any]?) {
            lock.lock()
            defer { lock.unlock() }
            self.query = query
        }

        func stringValue(for key: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return query?[key] as? String
        }
    }

    @Test func deleteConfirmedReturnsTrueOnSuccess() {
        let storage = KeychainTokenStorage(
            service: "com.cupthread.test",
            account: "test_account",
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            addItem: { _ in errSecSuccess },
            updateItem: { _, _ in errSecSuccess },
            copyItem: { _, _ in errSecSuccess },
            deleteItem: { _ in errSecSuccess }
        )

        #expect(storage.deleteConfirmed() == true)
    }

    @Test func deleteConfirmedReturnsTrueWhenItemNotFound() {
        let storage = KeychainTokenStorage(
            service: "com.cupthread.test",
            account: "test_account",
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            addItem: { _ in errSecSuccess },
            updateItem: { _, _ in errSecSuccess },
            copyItem: { _, _ in errSecSuccess },
            deleteItem: { _ in errSecItemNotFound }
        )

        #expect(storage.deleteConfirmed() == true)
    }

    @Test func deleteConfirmedReturnsFalseOnLockedKeychainFailure() {
        let storage = KeychainTokenStorage(
            service: "com.cupthread.test",
            account: "test_account",
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            addItem: { _ in errSecSuccess },
            updateItem: { _, _ in errSecSuccess },
            copyItem: { _, _ in errSecSuccess },
            deleteItem: { _ in errSecInteractionNotAllowed }
        )

        // Must report failure so callers (e.g. eraseMyData / reset) know the token was not deleted
        #expect(storage.deleteConfirmed() == false)
    }

    @Test func deleteConfirmedReturnsFalseOnAuthFailed() {
        let storage = KeychainTokenStorage(
            service: "com.cupthread.test",
            account: "test_account",
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            addItem: { _ in errSecSuccess },
            updateItem: { _, _ in errSecSuccess },
            copyItem: { _, _ in errSecSuccess },
            deleteItem: { _ in errSecAuthFailed }
        )

        #expect(storage.deleteConfirmed() == false)
    }

    @Test func deleteInvokesDeleteItemWithExpectedQuery() {
        let expectedService = "com.cupthread.test.service.\(UUID().uuidString)"
        let expectedAccount = "test.account.\(UUID().uuidString)"

        let recorder = QueryRecorder()
        let storage = KeychainTokenStorage(
            service: expectedService,
            account: expectedAccount,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            addItem: { _ in errSecSuccess },
            updateItem: { _, _ in errSecSuccess },
            copyItem: { _, _ in errSecSuccess },
            deleteItem: { query in
                recorder.record(query as? [String: Any])
                return errSecSuccess
            }
        )

        storage.delete()

        #expect(recorder.stringValue(for: kSecClass as String) == (kSecClassGenericPassword as String))
        #expect(recorder.stringValue(for: kSecAttrService as String) == expectedService)
        #expect(recorder.stringValue(for: kSecAttrAccount as String) == expectedAccount)
    }

    @Test func userTokenStoreResetPropagatesConfirmedDeletionOutcome() {
        let successfulStorage = KeychainTokenStorage(
            service: "com.cupthread.test",
            account: "test_account",
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            addItem: { _ in errSecSuccess },
            updateItem: { _, _ in errSecSuccess },
            copyItem: { _, _ in errSecSuccess },
            deleteItem: { _ in errSecSuccess }
        )
        let store1 = UserTokenStore(storage: successfulStorage)
        #expect(store1.reset() == true)

        let failingStorage = KeychainTokenStorage(
            service: "com.cupthread.test",
            account: "test_account",
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            addItem: { _ in errSecSuccess },
            updateItem: { _, _ in errSecSuccess },
            copyItem: { _, _ in errSecSuccess },
            deleteItem: { _ in errSecInteractionNotAllowed }
        )
        let store2 = UserTokenStore(storage: failingStorage)
        #expect(store2.reset() == false)
    }

    @Test func userDefaultsTokenStorageDeleteConfirmedSucceeds() {
        let suiteName = "test.userdefaults.delete.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = "test.key"
        let storage = UserDefaultsTokenStorage(userDefaults: defaults, key: key)
        storage.save("token-123")
        #expect(storage.load() == "token-123")

        #expect(storage.deleteConfirmed() == true)
        #expect(storage.load() == nil)
    }
}
