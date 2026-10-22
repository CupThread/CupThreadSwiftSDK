import Foundation
import Security
import Testing
@testable import CupThreadFeedback

// MARK: - ChangelogSubscriptionStore.clear() delete confirmation (SEC-29, #496)

@Suite("ChangelogSubscriptionStoreDeletion")
struct ChangelogSubscriptionStoreDeletionTests {
    @Test func clearReportsUnconfirmedDeletionAndKeepsRecordReadable() throws {
        // A locked Keychain (errSecInteractionNotAllowed on SecItemDelete) must
        // not pretend the record is gone: clear() reports failure and the
        // record stays readable and retryable (memory cache and legacy
        // plaintext included).
        let item = ScriptedKeychainItem()
        let storage = makeScriptedKeychainStorage(item: item)
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let store = ChangelogSubscriptionStore(
            appKey: "app_clear_unconfirmed_\(UUID().uuidString)",
            storage: storage,
            legacyUserDefaults: context.defaults
        )
        store.persist(record: ChangelogSubscriptionRecord(email: "user@example.com", state: .confirmed))
        #expect(store.subscribedEmail() == "user@example.com")

        #expect(store.clear() == false)

        #expect(storage.deleteConfirmed() == false)
        #expect(
            store.subscriptionRecord()
                == ChangelogSubscriptionRecord(email: "user@example.com", state: .confirmed)
        )
        #expect(store.subscribedEmail() == "user@example.com")
        #expect(item.data != nil)
    }

    @Test func clearRemovesRecordOnceKeychainDeletionIsConfirmed() throws {
        let item = ScriptedKeychainItem()
        let storage = makeScriptedKeychainStorage(item: item)
        let store = ChangelogSubscriptionStore(
            appKey: "app_clear_retry_\(UUID().uuidString)",
            storage: storage,
            legacyUserDefaults: nil
        )
        store.persist(record: ChangelogSubscriptionRecord(email: "user@example.com", state: .confirmed))
        #expect(store.clear() == false)

        // The Keychain becomes available; the retry must actually delete.
        item.failDeletion = false
        #expect(store.clear() == true)
        #expect(store.subscribedEmail() == nil)
        #expect(store.subscriptionRecord() == nil)
        #expect(item.data == nil)
    }

    @Test func clearPurgesLegacyPlaintextOnlyOnConfirmedDeletion() throws {
        let item = ScriptedKeychainItem()
        let storage = makeScriptedKeychainStorage(item: item)
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let store = ChangelogSubscriptionStore(
            appKey: "app_clear_legacy_\(UUID().uuidString)",
            storage: storage,
            legacyUserDefaults: context.defaults
        )
        store.persist(record: ChangelogSubscriptionRecord(email: "user@example.com", state: .confirmed))
        let storageKey = store.storageKey
        // A stale legacy copy (e.g. plaintext left by an earlier build) exists too.
        context.defaults.set("stale@example.com", forKey: storageKey)

        #expect(store.clear() == false)
        // An unconfirmed deletion keeps both copies truthful: the Keychain
        // item is still present, so the stale plaintext is not purged yet.
        #expect(item.data != nil)
        #expect(context.defaults.string(forKey: storageKey) == "stale@example.com")

        // Reads keep reporting the record (and purge the stale plaintext
        // themselves, as the migration path always has).
        #expect(store.subscribedEmail() == "user@example.com")

        item.failDeletion = false
        #expect(store.clear() == true)
        #expect(store.subscribedEmail() == nil)
        #expect(context.defaults.string(forKey: storageKey) == nil)
    }

    private func makeIsolatedDefaults() -> (defaults: UserDefaults, cleanup: () -> Void) {
        let suiteName = "test.changelogsubscriptiondeletion.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }
}
