import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("ChangelogSubscriptionStore")
struct ChangelogSubscriptionStoreTests {
    private struct IsolatedContext {
        let defaults: UserDefaults
        let suiteName: String

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func makeIsolatedDefaults() -> IsolatedContext {
        let suiteName = "test.changelogsubscriptionstore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return IsolatedContext(defaults: defaults, suiteName: suiteName)
    }

    @Test func freshStoreReadsEmptyAndRoundTripsPersistedEmail() throws {
        let storage = InMemorySubscriptionStorage()
        let store = ChangelogSubscriptionStore(appKey: "app_roundtrip", storage: storage)
        #expect(store.subscribedEmail() == nil)

        store.persist(email: "user@example.com")
        #expect(store.subscribedEmail() == "user@example.com")

        // A second instance over the same storage observes the same state.
        let reopened = ChangelogSubscriptionStore(appKey: "app_roundtrip", storage: storage)
        #expect(reopened.subscribedEmail() == "user@example.com")

        reopened.clear()
        #expect(store.subscribedEmail() == nil)
        #expect(reopened.subscribedEmail() == nil)
    }

    @Test func persistTrimsWhitespaceAndClearRemovesStorage() throws {
        let storage = InMemorySubscriptionStorage()
        let store = ChangelogSubscriptionStore(appKey: "app_trim", storage: storage)
        store.persist(email: "  user@example.com\n")
        #expect(store.subscribedEmail() == "user@example.com")

        // Whitespace-only input is ignored and never evicts an existing record.
        store.persist(email: "   ")
        #expect(store.subscribedEmail() == "user@example.com")

        store.clear()
        #expect(store.subscribedEmail() == nil)
    }

    @Test func persistOverwritesPreviousEmail() throws {
        let storage = InMemorySubscriptionStorage()
        let store = ChangelogSubscriptionStore(appKey: "app_overwrite", storage: storage)
        store.persist(email: "old@example.com")
        store.persist(email: "new@example.com")
        #expect(store.subscribedEmail() == "new@example.com")
    }

    @Test func storageIsScopedPerAppKey() throws {
        let storageA = InMemorySubscriptionStorage()
        let storageB = InMemorySubscriptionStorage()
        let storeA = ChangelogSubscriptionStore(appKey: "app_a", storage: storageA)
        let storeB = ChangelogSubscriptionStore(appKey: "app_b", storage: storageB)

        storeA.persist(email: "a@example.com")
        #expect(storeA.subscribedEmail() == "a@example.com")
        #expect(storeB.subscribedEmail() == nil)

        storeB.persist(email: "b@example.com")
        #expect(storeA.subscribedEmail() == "a@example.com")
        #expect(storeB.subscribedEmail() == "b@example.com")

        storeA.clear()
        #expect(storeA.subscribedEmail() == nil)
        #expect(storeB.subscribedEmail() == "b@example.com")
    }

    @Test func initialPhaseIsFormWithoutStoredEmailAndManageWithOne() {
        #expect(ChangelogSubscribeModel.initialPhase(subscribedEmail: nil) == .form)
        #expect(ChangelogSubscribeModel.initialPhase(subscribedEmail: "user@example.com") == .manage)
    }

    @Test func concurrentPersistAndReadNeverLosesAllWrites() async throws {
        let storage = InMemorySubscriptionStorage()
        let store = ChangelogSubscriptionStore(appKey: "app_concurrent", storage: storage)
        let emails = (0..<50).map { "user\($0)@example.com" }

        await withTaskGroup(of: Void.self) { group in
            for email in emails {
                group.addTask {
                    store.persist(email: email)
                    _ = store.subscribedEmail()
                }
            }
        }

        let final = try #require(store.subscribedEmail())
        #expect(emails.contains(final))
    }

    @Test func migrationAdoptsLegacyEmailAndPurgesFromUserDefaults() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let appKey = "app_migration_\(UUID().uuidString)"
        let storageKey = ChangelogSubscriptionStore.keyPrefix + appKey
        let legacyEmail = "migrated@example.com"
        context.defaults.set(legacyEmail, forKey: storageKey)

        let mockStorage = InMemorySubscriptionStorage()
        let store = ChangelogSubscriptionStore(
            appKey: appKey,
            storage: mockStorage,
            legacyUserDefaults: context.defaults
        )

        // First access adopts legacy email, persists to storage, and purges from UserDefaults
        #expect(store.subscribedEmail() == legacyEmail)
        #expect(mockStorage.load() == legacyEmail)
        #expect(context.defaults.string(forKey: storageKey) == nil)

        // Subsequent reads come from storage
        #expect(store.subscribedEmail() == legacyEmail)

        // A second store instance (fresh adoption state) reads the adopted email from storage
        // and does not resurrect anything in UserDefaults
        let secondStore = ChangelogSubscriptionStore(
            appKey: appKey,
            storage: mockStorage,
            legacyUserDefaults: context.defaults
        )
        #expect(secondStore.subscribedEmail() == legacyEmail)
        #expect(context.defaults.string(forKey: storageKey) == nil)
    }

    @Test func migrationWithKeychainStorageAdoptsLegacyEmailAndPurgesFromUserDefaults() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let appKey = "app_keychain_migration_\(UUID().uuidString)"
        let storageKey = ChangelogSubscriptionStore.keyPrefix + appKey
        let legacyEmail = "keychain-migrated@example.com"
        context.defaults.set(legacyEmail, forKey: storageKey)

        let store = ChangelogSubscriptionStore(
            appKey: appKey,
            legacyUserDefaults: context.defaults
        )
        defer { store.clear() }

        #expect(store.subscribedEmail() == legacyEmail)
        #expect(context.defaults.string(forKey: storageKey) == nil)

        // Verify it was stored in the system Keychain
        let keychainStorage = KeychainTokenStorage(
            service: ChangelogSubscriptionStore.keychainService,
            account: storageKey
        )
        #expect(keychainStorage.load() == legacyEmail)

        // A second store instance over the same app key
        let secondStore = ChangelogSubscriptionStore(
            appKey: appKey,
            legacyUserDefaults: context.defaults
        )
        #expect(secondStore.subscribedEmail() == legacyEmail)
        #expect(context.defaults.string(forKey: storageKey) == nil)
    }

    @Test func roundTripAndClearPurgesBothKeychainAndUserDefaults() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let appKey = "app_roundtrip_both_\(UUID().uuidString)"
        let storageKey = ChangelogSubscriptionStore.keyPrefix + appKey

        // Seed legacy UserDefaults as well to verify clear() wipes both backings
        context.defaults.set("stale@example.com", forKey: storageKey)

        let store = ChangelogSubscriptionStore(
            appKey: appKey,
            legacyUserDefaults: context.defaults
        )
        defer { store.clear() }

        store.persist(email: "  active@example.com \n")
        #expect(store.subscribedEmail() == "active@example.com")
        #expect(context.defaults.string(forKey: storageKey) == nil)

        let keychainStorage = KeychainTokenStorage(
            service: ChangelogSubscriptionStore.keychainService,
            account: storageKey
        )
        #expect(keychainStorage.load() == "active@example.com")

        // clear() purges both Keychain item and legacy UserDefaults
        context.defaults.set("lingering@example.com", forKey: storageKey)
        store.clear()

        #expect(store.subscribedEmail() == nil)
        #expect(keychainStorage.load() == nil)
        #expect(context.defaults.string(forKey: storageKey) == nil)
    }

    @Test func migrationRetriesWhenStorageWriteCannotBeConfirmed() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let appKey = "app_migration_unconfirmed_\(UUID().uuidString)"
        let storageKey = ChangelogSubscriptionStore.keyPrefix + appKey
        let legacyEmail = "retry@example.com"
        context.defaults.set(legacyEmail, forKey: storageKey)

        final class FailingConfirmedStorage: ChangelogSubscriptionStorage, @unchecked Sendable {
            func load() -> String? { nil }
            func save(_ email: String) {}
            func saveConfirmed(_ email: String) -> Bool { false }
            func delete() {}
        }

        let store = ChangelogSubscriptionStore(
            appKey: appKey,
            storage: FailingConfirmedStorage(),
            legacyUserDefaults: context.defaults
        )

        // Returns the email, but does not purge from UserDefaults because write failed
        #expect(store.subscribedEmail() == legacyEmail)
        #expect(context.defaults.string(forKey: storageKey) == legacyEmail)
    }

    @Test func legacyWhitespaceInUserDefaultsIsPurgedAndReturnsNil() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let appKey = "app_whitespace_\(UUID().uuidString)"
        let storageKey = ChangelogSubscriptionStore.keyPrefix + appKey
        context.defaults.set("   \n\t ", forKey: storageKey)

        let mockStorage = InMemorySubscriptionStorage()
        let store = ChangelogSubscriptionStore(
            appKey: appKey,
            storage: mockStorage,
            legacyUserDefaults: context.defaults
        )

        #expect(store.subscribedEmail() == nil)
        #expect(mockStorage.load() == nil)
        #expect(context.defaults.string(forKey: storageKey) == nil)
    }
}
