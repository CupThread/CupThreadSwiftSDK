import Foundation
import Testing
@testable import CupThreadFeedback

@Suite("UserTokenStore")
struct UserTokenStoreTests {

    private struct IsolatedContext {
        let defaults: UserDefaults
        let suiteName: String

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func makeIsolatedDefaults() -> IsolatedContext {
        let suiteName = "test.usertokenstore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return IsolatedContext(defaults: defaults, suiteName: suiteName)
    }

    @Test func concurrentFirstAccessResolvesIdenticalToken() async throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let testKey = "test.token.\(UUID().uuidString)"
        let store = UserTokenStore(userDefaults: context.defaults, key: testKey)

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

        let resolvedToken = try #require(uniqueTokens.first)
        #expect(!resolvedToken.isEmpty)
        #expect(UUID(uuidString: resolvedToken) != nil)

        let persisted = context.defaults.string(forKey: testKey)
        #expect(persisted == resolvedToken)
    }

    @Test func multiInstanceConcurrentFirstAccessResolvesIdenticalToken() async throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let testKey = "test.token.\(UUID().uuidString)"
        let concurrency = 64

        let suite = context.suiteName
        let tokens = await withTaskGroup(of: String.self) { group in
            for _ in 0..<concurrency {
                group.addTask {
                    let taskDefaults = UserDefaults(suiteName: suite)!
                    let instance = UserTokenStore(userDefaults: taskDefaults, key: testKey)
                    return instance.token
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

        let resolvedToken = try #require(uniqueTokens.first)
        #expect(!resolvedToken.isEmpty)
        #expect(UUID(uuidString: resolvedToken) != nil)

        let persisted = context.defaults.string(forKey: testKey)
        #expect(persisted == resolvedToken)
    }

    @Test func subsequentReadsReusePersistedToken() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let testKey = "test.token.\(UUID().uuidString)"
        let store1 = UserTokenStore(userDefaults: context.defaults, key: testKey)

        let initialToken = store1.token
        #expect(!initialToken.isEmpty)

        // Same instance subsequent reads
        for _ in 0..<10 {
            #expect(store1.token == initialToken)
        }

        // New instance re-reading same defaults key
        let store2 = UserTokenStore(userDefaults: context.defaults, key: testKey)
        #expect(store2.token == initialToken)
    }

    @Test func preExistingTokenInUserDefaultsIsRespected() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let testKey = "test.token.\(UUID().uuidString)"
        let existingUUID = UUID().uuidString
        context.defaults.set(existingUUID, forKey: testKey)

        let store = UserTokenStore(userDefaults: context.defaults, key: testKey)
        #expect(store.token == existingUUID)
    }

    @Test func emptyStringInUserDefaultsTriggersFreshMint() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let testKey = "test.token.\(UUID().uuidString)"
        context.defaults.set("", forKey: testKey)

        let store = UserTokenStore(userDefaults: context.defaults, key: testKey)
        let token = store.token
        #expect(!token.isEmpty)
        #expect(UUID(uuidString: token) != nil)
        #expect(context.defaults.string(forKey: testKey) == token)
    }

    @Test func sharedStoreReturnsValidUUIDAndPersists() throws {
        let token = UserTokenStore.shared.token
        #expect(!token.isEmpty)
        #expect(UUID(uuidString: token) != nil)

        // Stable on repeated calls
        #expect(UserTokenStore.shared.token == token)

        // Matches stored default
        let persisted = UserDefaults.standard.string(forKey: UserTokenStore.defaultKey)
        #expect(persisted == token)
    }
}
