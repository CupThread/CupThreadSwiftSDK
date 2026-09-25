import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("ChangelogSeenStore", .serialized)
struct ChangelogSeenStoreTests {
    private struct IsolatedContext {
        let defaults: UserDefaults
        let suiteName: String

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func makeIsolatedDefaults() -> IsolatedContext {
        let suiteName = "test.changelogseenstore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return IsolatedContext(defaults: defaults, suiteName: suiteName)
    }

    @Test func capPrunesOldestEntriesWhenExceedingCapacity() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let store = ChangelogSeenStore(
            appKey: "app_cap_test",
            userDefaults: context.defaults,
            maxCapacity: 64
        )

        for index in 0..<100 {
            store.markSeen("version-\(index)")
        }

        let stored = store.storedVersions()
        #expect(stored.count == 64)

        // The first 36 versions (0..<36) must have been pruned oldest-first.
        for index in 0..<36 {
            #expect(store.hasSeen("version-\(index)") == false)
        }

        // The newest 64 versions (36..<100) must still be seen.
        for index in 36..<100 {
            #expect(store.hasSeen("version-\(index)") == true)
        }

        let expectedStored = (36..<100).map { "version-\($0)" }
        #expect(stored == expectedStored)
    }

    @Test func idempotentMarkStoresSingleEntryWithoutDuplicateWrites() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let store = ChangelogSeenStore(appKey: "app_idempotent", userDefaults: context.defaults)

        #expect(store.hasSeen("1.0.0") == false)
        #expect(store.writeCount == 0)

        store.markSeen("1.0.0")
        #expect(store.hasSeen("1.0.0") == true)
        #expect(store.storedVersions() == ["1.0.0"])
        #expect(store.writeCount == 1)

        // Second mark of the exact same version should be an idempotent no-op.
        store.markSeen("1.0.0")
        #expect(store.hasSeen("1.0.0") == true)
        #expect(store.storedVersions() == ["1.0.0"])
        #expect(store.writeCount == 1)
    }

    @Test func concurrentMarkingPreservesAllMarksWithoutLostUpdates() async throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let store = ChangelogSeenStore(
            appKey: "app_concurrent",
            userDefaults: context.defaults,
            maxCapacity: 64
        )

        let concurrency = 50
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<concurrency {
                group.addTask {
                    store.markSeen("concurrent-version-\(index)")
                }
            }
        }

        #expect(store.storedVersions().count == concurrency)
        #expect(store.writeCount == concurrency)

        for index in 0..<concurrency {
            #expect(store.hasSeen("concurrent-version-\(index)") == true)
        }
    }

    @Test func entryAndLabelPairingMarksBothAsSeen() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let store = ChangelogSeenStore(appKey: "app_pairing", userDefaults: context.defaults)

        let entryID = "e_release_42"
        let versionLabel = "2.5.0"

        #expect(store.hasSeen(entryID) == false)
        #expect(store.hasSeen(versionLabel) == false)

        store.markSeen(id: entryID, versionLabel: versionLabel)

        #expect(store.hasSeen(entryID) == true)
        #expect(store.hasSeen(versionLabel) == true)
        #expect(store.storedVersions() == [entryID, versionLabel])
        #expect(store.writeCount == 1)
    }

    @Test func doubleMarkPassPerformsNoAdditionalWrites() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let store = ChangelogSeenStore(appKey: "app_dedup", userDefaults: context.defaults)

        let entryID = "e_release_99"
        let versionLabel = "3.1.0"

        // First pass (simulating close/primary or onDisappear)
        store.markSeen(entryID)
        store.markSeen(versionLabel)
        #expect(store.writeCount == 2)
        #expect(store.storedVersions() == [entryID, versionLabel])

        // Second pass (simulating re-entry on dismiss)
        store.markSeen(entryID)
        store.markSeen(versionLabel)
        #expect(store.writeCount == 2)
        #expect(store.storedVersions() == [entryID, versionLabel])
    }

    @Test func multipleAppKeysAreIsolated() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let storeA = ChangelogSeenStore(appKey: "app_A", userDefaults: context.defaults)
        let storeB = ChangelogSeenStore(appKey: "app_B", userDefaults: context.defaults)

        storeA.markSeen("1.0.0")

        #expect(storeA.hasSeen("1.0.0") == true)
        #expect(storeB.hasSeen("1.0.0") == false)
        #expect(storeA.storedVersions() == ["1.0.0"])
        #expect(storeB.storedVersions().isEmpty)
    }

    @Test func legacyUnboundedStorageIsPrunedOnNextMark() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let appKey = "app_legacy"
        let storageKey = "com.cupthread.changelog.seenVersions.\(appKey)"

        // Seed 100 entries simulating legacy unpruned storage.
        let legacyEntries = (0..<100).map { "legacy-\($0)" }
        context.defaults.set(legacyEntries, forKey: storageKey)

        let store = ChangelogSeenStore(
            appKey: appKey,
            userDefaults: context.defaults,
            maxCapacity: 64
        )

        // Before new marks, legacy data is readable.
        #expect(store.hasSeen("legacy-0") == true)
        #expect(store.hasSeen("legacy-99") == true)
        #expect(store.storedVersions().count == 100)

        // Adding a new mark prunes the list to maxCapacity (64).
        store.markSeen("new-release")
        let stored = store.storedVersions()
        #expect(stored.count == 64)
        #expect(store.hasSeen("legacy-0") == false)
        #expect(store.hasSeen("legacy-99") == true)
        #expect(store.hasSeen("new-release") == true)
    }

    @Test func clientDelegatesToChangelogSeenStore() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let appKey = "app_client_delegate_\(UUID().uuidString)"
        let customStore = ChangelogSeenStore(appKey: appKey, userDefaults: context.defaults)
        ChangelogSeenStore.register(customStore, for: appKey)
        defer { ChangelogSeenStore.resetRegistry() }

        let client = makeClient(appKey: appKey)

        #expect(client.hasSeenChangelog(version: "1.0.0") == false)
        client.markChangelogSeen(version: "1.0.0")
        #expect(client.hasSeenChangelog(version: "1.0.0") == true)
        #expect(customStore.storedVersions() == ["1.0.0"])
    }

    @Test func markSeenWithIdAndVersionLabelPerformsSingleWriteAndSinglePruneAtCapacity() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let store = ChangelogSeenStore(appKey: "app_cap_test", userDefaults: context.defaults, maxCapacity: 10)
        for index in 0..<10 {
            store.markSeen("version-\(index)")
        }
        #expect(store.storedVersions().count == 10)
        let initialWrites = store.writeCount

        // Atomic mark of entry with both ID and label
        store.markSeen(id: "entry-new", versionLabel: "v2.0.0")

        // Must perform exactly 1 UserDefaults write
        #expect(store.writeCount == initialWrites + 1)

        // Total count must be bounded at maxCapacity (10)
        let stored = store.storedVersions()
        #expect(stored.count == 10)

        // Both new tokens are marked as seen
        #expect(store.hasSeen("entry-new") == true)
        #expect(store.hasSeen("v2.0.0") == true)
    }

    @Test func clientDelegatesAtomicMarkToChangelogSeenStore() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let appKey = "app_client_delegate_atomic_\(UUID().uuidString)"
        let customStore = ChangelogSeenStore(appKey: appKey, userDefaults: context.defaults)
        ChangelogSeenStore.register(customStore, for: appKey)
        defer { ChangelogSeenStore.resetRegistry() }

        let client = makeClient(appKey: appKey)

        #expect(client.hasSeenChangelog(version: "entry-1") == false)
        #expect(client.hasSeenChangelog(version: "1.0.0") == false)

        client.markChangelogSeen(id: "entry-1", versionLabel: "1.0.0")

        #expect(client.hasSeenChangelog(version: "entry-1") == true)
        #expect(client.hasSeenChangelog(version: "1.0.0") == true)
        #expect(customStore.storedVersions() == ["entry-1", "1.0.0"])
        #expect(customStore.writeCount == 1)
    }
}
