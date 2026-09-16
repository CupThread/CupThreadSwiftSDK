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
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let store = ChangelogSubscriptionStore(appKey: "app_roundtrip", userDefaults: context.defaults)
        #expect(store.subscribedEmail() == nil)

        store.persist(email: "user@example.com")
        #expect(store.subscribedEmail() == "user@example.com")

        // A second instance over the same storage observes the same state.
        let reopened = ChangelogSubscriptionStore(appKey: "app_roundtrip", userDefaults: context.defaults)
        #expect(reopened.subscribedEmail() == "user@example.com")

        reopened.clear()
        #expect(store.subscribedEmail() == nil)
        #expect(reopened.subscribedEmail() == nil)
    }

    @Test func persistTrimsWhitespaceAndClearRemovesStorage() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let store = ChangelogSubscriptionStore(appKey: "app_trim", userDefaults: context.defaults)
        store.persist(email: "  user@example.com\n")
        #expect(store.subscribedEmail() == "user@example.com")

        // Whitespace-only input is ignored and never evicts an existing record.
        store.persist(email: "   ")
        #expect(store.subscribedEmail() == "user@example.com")

        store.clear()
        #expect(store.subscribedEmail() == nil)
    }

    @Test func persistOverwritesPreviousEmail() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let store = ChangelogSubscriptionStore(appKey: "app_overwrite", userDefaults: context.defaults)
        store.persist(email: "old@example.com")
        store.persist(email: "new@example.com")
        #expect(store.subscribedEmail() == "new@example.com")
    }

    @Test func storageIsScopedPerAppKey() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let storeA = ChangelogSubscriptionStore(appKey: "app_a", userDefaults: context.defaults)
        let storeB = ChangelogSubscriptionStore(appKey: "app_b", userDefaults: context.defaults)

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
        #expect(ChangelogSubscribeView.initialPhase(subscribedEmail: nil) == .form)
        #expect(ChangelogSubscribeView.initialPhase(subscribedEmail: "user@example.com") == .manage)
    }

    @Test func concurrentPersistAndReadNeverLosesAllWrites() async throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let store = ChangelogSubscriptionStore(appKey: "app_concurrent", userDefaults: context.defaults)
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
}
