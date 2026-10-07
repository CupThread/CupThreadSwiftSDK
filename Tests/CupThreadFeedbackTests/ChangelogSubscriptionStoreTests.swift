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

    @Test func freshStoreReadsNoRecordAndRoundTripsBothStates() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let store = ChangelogSubscriptionStore(appKey: "app_roundtrip", userDefaults: context.defaults)
        #expect(store.subscriptionRecord() == nil)
        #expect(store.subscribedEmail() == nil)

        let since = Date(timeIntervalSince1970: 1_760_000_000)
        store.persist(record: ChangelogSubscriptionRecord(email: "user@example.com", state: .pending(since: since)))
        #expect(
            store.subscriptionRecord()
                == ChangelogSubscriptionRecord(email: "user@example.com", state: .pending(since: since))
        )
        #expect(store.subscribedEmail() == "user@example.com")

        // A second instance over the same storage observes the same state.
        let reopened = ChangelogSubscriptionStore(appKey: "app_roundtrip", userDefaults: context.defaults)
        #expect(
            reopened.subscriptionRecord()
                == ChangelogSubscriptionRecord(email: "user@example.com", state: .pending(since: since))
        )

        reopened.clear()
        #expect(store.subscriptionRecord() == nil)
        #expect(reopened.subscriptionRecord() == nil)
    }

    @Test func confirmedStateRoundTrips() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let store = ChangelogSubscriptionStore(appKey: "app_confirmed", userDefaults: context.defaults)
        store.persist(record: ChangelogSubscriptionRecord(email: "user@example.com", state: .confirmed))
        #expect(
            store.subscriptionRecord()
                == ChangelogSubscriptionRecord(email: "user@example.com", state: .confirmed)
        )
        #expect(store.subscriptionRecord()?.state.isPending == false)
    }

    @Test func legacyBareEmailReadsBackAsConfirmed() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let store = ChangelogSubscriptionStore(appKey: "app_legacy", userDefaults: context.defaults)
        // Exactly the value pre-#273 SDK versions wrote: a bare email string.
        context.defaults.set("legacy@example.com", forKey: store.storageKey)

        #expect(store.subscribedEmail() == "legacy@example.com")
        #expect(
            store.subscriptionRecord()
                == ChangelogSubscriptionRecord(email: "legacy@example.com", state: .confirmed)
        )
    }

    @Test func persistTrimsWhitespaceAndClearRemovesStorage() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let store = ChangelogSubscriptionStore(appKey: "app_trim", userDefaults: context.defaults)
        store.persist(
            record: ChangelogSubscriptionRecord(email: "  user@example.com\n", state: .confirmed)
        )
        #expect(store.subscribedEmail() == "user@example.com")

        // Whitespace-only input is ignored and never evicts an existing record.
        store.persist(record: ChangelogSubscriptionRecord(email: "   ", state: .confirmed))
        #expect(store.subscribedEmail() == "user@example.com")

        store.clear()
        #expect(store.subscriptionRecord() == nil)
    }

    @Test func persistOverwritesPreviousEmailAndState() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let store = ChangelogSubscriptionStore(appKey: "app_overwrite", userDefaults: context.defaults)
        store.persist(record: ChangelogSubscriptionRecord(email: "old@example.com", state: .confirmed))
        let since = Date(timeIntervalSince1970: 1_760_000_100)
        store.persist(record: ChangelogSubscriptionRecord(email: "new@example.com", state: .pending(since: since)))
        #expect(
            store.subscriptionRecord()
                == ChangelogSubscriptionRecord(email: "new@example.com", state: .pending(since: since))
        )
    }

    @Test func storageIsScopedPerAppKey() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let storeA = ChangelogSubscriptionStore(appKey: "app_a", userDefaults: context.defaults)
        let storeB = ChangelogSubscriptionStore(appKey: "app_b", userDefaults: context.defaults)

        storeA.persist(record: ChangelogSubscriptionRecord(email: "a@example.com", state: .confirmed))
        #expect(storeA.subscribedEmail() == "a@example.com")
        #expect(storeB.subscriptionRecord() == nil)

        let pending = ChangelogSubscriptionRecord(email: "b@example.com", state: .pending(since: .now))
        storeB.persist(record: pending)
        #expect(storeA.subscribedEmail() == "a@example.com")
        #expect(storeB.subscriptionRecord() == pending)

        storeA.clear()
        #expect(storeA.subscriptionRecord() == nil)
        #expect(storeB.subscriptionRecord() == pending)
    }

    @Test func initialPhaseIsFormWithoutStoredEmailAndManageWithOne() {
        #expect(ChangelogSubscribeModel.initialPhase(subscribedEmail: nil) == .form)
        #expect(ChangelogSubscribeModel.initialPhase(subscribedEmail: "user@example.com") == .manage)
    }

    @Test func concurrentPersistAndReadNeverLosesAllWrites() async throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let store = ChangelogSubscriptionStore(appKey: "app_concurrent", userDefaults: context.defaults)
        let emails = (0..<50).map { "user\($0)@example.com" }

        await withTaskGroup(of: Void.self) { group in
            for email in emails {
                group.addTask {
                    store.persist(record: ChangelogSubscriptionRecord(email: email, state: .confirmed))
                    _ = store.subscriptionRecord()
                }
            }
        }

        let final = try #require(store.subscriptionRecord())
        #expect(emails.contains(final.email))
    }
}
