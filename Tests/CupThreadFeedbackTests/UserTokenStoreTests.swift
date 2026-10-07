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

    @Test func sharedStoreReturnsValidUUIDAndPersistsInKeychain() throws {
        let token = UserTokenStore.shared.token
        #expect(!token.isEmpty)
        #expect(UUID(uuidString: token) != nil)

        // Stable on repeated calls
        #expect(UserTokenStore.shared.token == token)

        // Stored securely in Keychain, not in plaintext UserDefaults
        let keychainStorage = KeychainTokenStorage(
            service: KeychainTokenStorage.defaultService,
            account: UserTokenStore.defaultKey
        )
        #expect(keychainStorage.load() == token)

        // Purged from UserDefaults to prevent appearing in unencrypted backups
        let persistedInDefaults = UserDefaults.standard.string(forKey: UserTokenStore.defaultKey)
        #expect(persistedInDefaults == nil)
    }

    @Test func migrationAdoptsLegacyTokenAndPurgesFromUserDefaults() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let testKey = "test.migration.\(UUID().uuidString)"
        let legacyToken = "legacy-token-\(UUID().uuidString)"
        context.defaults.set(legacyToken, forKey: testKey)

        let mockStorage = InMemoryTokenStorage()
        let store = UserTokenStore(
            storage: mockStorage,
            legacyUserDefaults: context.defaults,
            legacyKey: testKey
        )

        // First access adopts legacy token and purges it from UserDefaults
        let resolved = store.token
        #expect(resolved == legacyToken)
        #expect(mockStorage.load() == legacyToken)
        #expect(context.defaults.string(forKey: testKey) == nil)

        // Subsequent reads come from storage, not defaults
        context.defaults.set("tampered-token", forKey: testKey)
        #expect(store.token == legacyToken)
    }

    @Test func keychainStorageSavesLoadsAndDeletes() throws {
        let testService = "com.cupthread.test.\(UUID().uuidString)"
        let testAccount = "account.\(UUID().uuidString)"
        let storage = KeychainTokenStorage(service: testService, account: testAccount)
        defer { storage.delete() }

        #expect(storage.load() == nil)

        let token1 = UUID().uuidString
        storage.save(token1)
        #expect(storage.load() == token1)

        // Overwrite existing value (triggers update branch)
        let token2 = UUID().uuidString
        storage.save(token2)
        #expect(storage.load() == token2)

        storage.delete()
        #expect(storage.load() == nil)
    }

    @Test func saveConfirmedPersistsAndReportsSuccess() throws {
        let testService = "com.cupthread.test.saveconfirmed.\(UUID().uuidString)"
        let testAccount = "account.\(UUID().uuidString)"
        let storage = KeychainTokenStorage(service: testService, account: testAccount)
        defer { storage.delete() }

        // Add path.
        #expect(storage.saveConfirmed(UUID().uuidString))
        let first = storage.load()
        #expect(first != nil)

        // Duplicate path falls back to SecItemUpdate and still reports success.
        let second = UUID().uuidString
        #expect(storage.saveConfirmed(second))
        #expect(storage.load() == second)
    }

    @Test func saveConfirmedReportsAddFailureInsteadOfSwallowingIt() {
        let updates = InvocationRecorder()
        let storage = scriptedKeychainStorage(
            addStatus: errSecInteractionNotAllowed,
            updateStatus: errSecSuccess,
            updates: updates
        )

        // An inaccessible Keychain (e.g. before first unlock) must surface as
        // a failed write, not silently disappear.
        #expect(storage.saveConfirmed("token") == false)
        #expect(updates.invocations == 0)
    }

    @Test func saveConfirmedReportsAnyNonSuccessAddStatus() {
        let updates = InvocationRecorder()
        let storage = scriptedKeychainStorage(
            addStatus: errSecMissingEntitlement,
            updateStatus: errSecSuccess,
            updates: updates
        )

        #expect(storage.saveConfirmed("token") == false)
        #expect(updates.invocations == 0)
    }

    @Test func saveConfirmedDuplicatePathUpdatesAndReportsSuccess() {
        let updates = InvocationRecorder()
        let storage = scriptedKeychainStorage(
            addStatus: errSecDuplicateItem,
            updateStatus: errSecSuccess,
            updates: updates
        )

        #expect(storage.saveConfirmed("token") == true)
        #expect(updates.invocations == 1)
    }

    @Test func saveConfirmedReportsFailedDuplicateUpdate() {
        let updates = InvocationRecorder()
        let storage = scriptedKeychainStorage(
            addStatus: errSecDuplicateItem,
            updateStatus: errSecInteractionNotAllowed,
            updates: updates
        )

        // The duplicate path must not claim success when SecItemUpdate fails.
        #expect(storage.saveConfirmed("token") == false)
        #expect(updates.invocations == 1)
    }

    @Test func inaccessibleKeychainAdoptionServesLegacyIdentityWithoutConsumingFlag() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let legacyToken = UUID().uuidString
        let legacyKeychainKey = "test.sec13.global.\(UUID().uuidString)"
        let flagKey = "test.sec13.flag.\(UUID().uuidString)"
        context.defaults.set(legacyToken, forKey: legacyKeychainKey)

        // A Keychain that rejects every write, as one does before first unlock.
        let storage = KeychainTokenStorage(
            service: "com.cupthread.test.sec13.\(UUID().uuidString)",
            account: "account.\(UUID().uuidString)",
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            addItem: { _ in errSecInteractionNotAllowed },
            updateItem: { _, _ in errSecInteractionNotAllowed }
        )
        let store = UserTokenStore(
            storage: storage,
            legacyUserDefaults: context.defaults,
            legacyKey: "unused",
            legacyGlobalStore: UserDefaultsTokenStorage(userDefaults: context.defaults, key: legacyKeychainKey),
            adoptionDefaults: context.defaults,
            adoptionFlagKey: flagKey
        )

        // The legacy identity is served for this read while the flag stays
        // unset, so a later writable Keychain re-runs adoption instead of
        // permanently rotating the end-user identity (SEC-13).
        #expect(store.token == legacyToken)
        #expect(context.defaults.bool(forKey: flagKey) == false)
    }

    @Test func migrationWithRealKeychainTransfersLegacyToken() throws {
        let context = makeIsolatedDefaults()
        defer { context.cleanup() }

        let testKey = "test.migration.\(UUID().uuidString)"
        let legacyToken = UUID().uuidString
        context.defaults.set(legacyToken, forKey: testKey)

        let testService = "com.cupthread.test.migration.\(UUID().uuidString)"
        let testAccount = "account.\(UUID().uuidString)"
        let keychainStorage = KeychainTokenStorage(service: testService, account: testAccount)
        defer { keychainStorage.delete() }

        let store = UserTokenStore(
            storage: keychainStorage,
            legacyUserDefaults: context.defaults,
            legacyKey: testKey
        )

        let resolved = store.token
        #expect(resolved == legacyToken)
        #expect(keychainStorage.load() == legacyToken)
        #expect(context.defaults.string(forKey: testKey) == nil)
    }

    @Test func freshMintOnCleanStorePersistsAndReusesToken() throws {
        let testService = "com.cupthread.test.fresh.\(UUID().uuidString)"
        let testAccount = "account.\(UUID().uuidString)"
        let keychainStorage = KeychainTokenStorage(service: testService, account: testAccount)
        defer { keychainStorage.delete() }

        let store = UserTokenStore(
            storage: keychainStorage,
            legacyUserDefaults: nil,
            legacyKey: nil
        )

        let minted = store.token
        #expect(!minted.isEmpty)
        #expect(UUID(uuidString: minted) != nil)

        // Second access reuses the minted token
        #expect(store.token == minted)
        #expect(keychainStorage.load() == minted)
    }

    @Test func concurrentFirstAccessOnKeychainResolvesIdenticalToken() async throws {
        let testService = "com.cupthread.test.concurrency.\(UUID().uuidString)"
        let testAccount = "account.\(UUID().uuidString)"
        let keychainStorage = KeychainTokenStorage(service: testService, account: testAccount)
        defer { keychainStorage.delete() }

        let store = UserTokenStore(
            storage: keychainStorage,
            legacyUserDefaults: nil,
            legacyKey: nil
        )

        let concurrency = 32
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

        let resolved = try #require(uniqueTokens.first)
        #expect(keychainStorage.load() == resolved)
    }
}

/// Builds a `KeychainTokenStorage` whose `SecItemAdd`/`SecItemUpdate` outcomes
/// are scripted, so write-status handling is testable without real Keychain I/O.
private func scriptedKeychainStorage(
    addStatus: OSStatus,
    updateStatus: OSStatus,
    updates: InvocationRecorder
) -> KeychainTokenStorage {
    KeychainTokenStorage(
        service: "com.cupthread.test.scripted.\(UUID().uuidString)",
        account: "account.\(UUID().uuidString)",
        accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        addItem: { _ in addStatus },
        updateItem: { _, _ in
            updates.record()
            return updateStatus
        }
    )
}

/// Thread-safe invocation counter for scripted `SecItemUpdate` seams.
private final class InvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var invocations: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func record() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}

private final class InMemoryTokenStorage: TokenStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var storedToken: String?

    init(initialToken: String? = nil) {
        self.storedToken = initialToken
    }

    func load() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storedToken
    }

    func save(_ token: String) {
        lock.lock()
        defer { lock.unlock() }
        storedToken = token
    }

    func delete() {
        lock.lock()
        defer { lock.unlock() }
        storedToken = nil
    }
}
