import Foundation
import Security
import Testing
@testable import CupThreadFeedback

/// Regression coverage for issue #567: while a backing store is unreadable
/// (SEC-7) or cannot confirm a write, ``UserTokenStore/token`` must serve the
/// *same* ephemeral token on every read — memoized per backing store for the
/// process lifetime — instead of minting a fresh UUID per call, which bound a
/// different end-user identity to each step of one logical operation. The
/// memo must never shadow a durable identity: it drops when a read resolves a
/// stored token, when a write is confirmed, and when a confirmed ``reset()``
/// erases the item, and no write is ever issued behind an inaccessible read.
@Suite("UserTokenStore Ephemeral Memo (issue #567)")
struct UserTokenStoreEphemeralMemoTests {

    @Test func repeatedInaccessibleReadsServeOneEphemeralToken() {
        let adds = WriteCounter()
        let updates = WriteCounter()
        let storage = lockedKeychainStorage(adds: adds, updates: updates)
        let store = UserTokenStore(storage: storage, legacyUserDefaults: nil, legacyKey: nil)

        let first = store.token
        let second = store.token
        let third = store.token

        #expect(UUID(uuidString: first) != nil)
        #expect(first == second)
        #expect(second == third)
        #expect(first == first.lowercased())

        // The memo never authorizes a write: the unreadable item is not
        // touched on any of the three reads (SEC-7).
        #expect(adds.isEmpty)
        #expect(updates.isEmpty)
    }

    @Test func ephemeralMemoIsSharedAcrossStoreInstancesForTheSameBackingItem() {
        // Two independent store instances over the same Keychain item
        // (same service + account, as ad-hoc `UserTokenStore(appKey:)`
        // construction produces) must present one run identity.
        let service = "com.cupthread.test.memo.shared.\(UUID().uuidString)"
        let account = "account.\(UUID().uuidString)"

        let firstStore = UserTokenStore(
            storage: lockedKeychainStorage(service: service, account: account),
            legacyUserDefaults: nil,
            legacyKey: nil
        )
        let secondStore = UserTokenStore(
            storage: lockedKeychainStorage(service: service, account: account),
            legacyUserDefaults: nil,
            legacyKey: nil
        )

        #expect(firstStore.token == secondStore.token)
    }

    @Test func scopedStoresNeverShareTheEphemeralMemoAcrossBackingItems() {
        // One identity per app: two distinct backing items must never serve
        // the same ephemeral token, even while both are inaccessible.
        let firstStore = UserTokenStore(
            storage: lockedKeychainStorage(),
            legacyUserDefaults: nil,
            legacyKey: nil
        )
        let secondStore = UserTokenStore(
            storage: lockedKeychainStorage(),
            legacyUserDefaults: nil,
            legacyKey: nil
        )

        #expect(firstStore.token != secondStore.token)
    }

    @Test func storedIdentityDropsTheMemoWhenTheStoreBecomesReadable() {
        let storedToken = UUID().uuidString
        let gate = GatedTokenStorage(storedToken: storedToken)
        let store = UserTokenStore(storage: gate, legacyUserDefaults: nil, legacyKey: nil)

        let lockedWindowToken = store.token
        #expect(store.token == lockedWindowToken)
        #expect(gate.writeAttempts == 0)

        // The stored identity wins as soon as the store becomes readable,
        // and the memo is dropped with it.
        gate.makeReadable()
        #expect(store.token == storedToken)

        // A later inaccessible window starts a fresh run: the pre-unlock
        // ephemeral identity is not resurrected.
        gate.makeUnreadable()
        let nextWindowToken = store.token
        #expect(UUID(uuidString: nextWindowToken) != nil)
        #expect(nextWindowToken != lockedWindowToken)
        #expect(gate.writeAttempts == 0)
    }

    @Test func confirmedResetDropsTheMemoEvenWhileTheStoreStaysUnreadable() {
        // A deletion can confirm while reads stay locked; the confirmed
        // erasure ends the run, so the pre-reset ephemeral identity is not
        // resurrected and no write is issued for the replacement.
        let adds = WriteCounter()
        let updates = WriteCounter()
        let storage = KeychainTokenStorage(
            service: "com.cupthread.test.memo.reset.\(UUID().uuidString)",
            account: "account.\(UUID().uuidString)",
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            addItem: { _ in
                adds.record()
                return errSecSuccess
            },
            updateItem: { _, _ in
                updates.record()
                return errSecSuccess
            },
            copyItem: { _, _ in errSecInteractionNotAllowed },
            deleteItem: { _ in errSecSuccess }
        )
        let store = UserTokenStore(storage: storage, legacyUserDefaults: nil, legacyKey: nil)

        let preResetToken = store.token
        #expect(store.token == preResetToken)
        #expect(store.reset())

        let postResetToken = store.token
        #expect(UUID(uuidString: postResetToken) != nil)
        #expect(postResetToken != preResetToken)
        #expect(store.token == postResetToken)
        #expect(adds.isEmpty)
        #expect(updates.isEmpty)
    }

    @Test func failedResetKeepsTheMemo() {
        // A reset that could not be confirmed did not erase anything, so the
        // unresolved run keeps its identity.
        let storage = KeychainTokenStorage(
            service: "com.cupthread.test.memo.resetfail.\(UUID().uuidString)",
            account: "account.\(UUID().uuidString)",
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            addItem: { _ in errSecSuccess },
            updateItem: { _, _ in errSecSuccess },
            copyItem: { _, _ in errSecInteractionNotAllowed },
            deleteItem: { _ in errSecInteractionNotAllowed }
        )
        let store = UserTokenStore(storage: storage, legacyUserDefaults: nil, legacyKey: nil)

        let token = store.token
        #expect(!store.reset())
        #expect(store.token == token)
    }

    @Test func unconfirmedWriteRetriesPersistingTheMemoizedToken() {
        let storage = UnconfirmedWriteTokenStorage()
        let store = UserTokenStore(storage: storage, legacyUserDefaults: nil, legacyKey: nil)

        // Every read in the unconfirmed window serves one identity while
        // persistence is retried on every read with that same value.
        let first = store.token
        let second = store.token
        #expect(first == second)
        #expect(storage.acceptedTokens.isEmpty)
        #expect(storage.writeAttempts == [first, first])

        // Once writes confirm, the already-served identity gains a durable
        // home instead of rotating to a fresh UUID.
        storage.allowConfirmedWrites()
        let third = store.token
        #expect(third == first)
        #expect(storage.acceptedTokens == [first])
        #expect(storage.load() == first)

        // The persisted identity wins thereafter, even through a later
        // unconfirmed window (the memo was dropped on confirmation).
        storage.rejectConfirmedWrites()
        #expect(store.token == first)
    }

    @Test func inaccessibleLegacyGlobalReadServesOneEphemeralToken() throws {
        let suiteName = "test.ephemeralmemo.sec18.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyToken = "legacy_global_token_\(UUID().uuidString)"
        let globalStorage = GatedTokenStorage(storedToken: legacyToken)
        let scopedKey = "test.ephemeralmemo.scoped.\(UUID().uuidString)"
        let scopedStorage = UserDefaultsTokenStorage(userDefaults: defaults, key: scopedKey)

        let flagKey = "test.ephemeralmemo.flag.\(UUID().uuidString)"
        let store = UserTokenStore(
            storage: scopedStorage,
            legacyUserDefaults: defaults,
            legacyKey: "unused",
            legacyGlobalStore: globalStorage,
            adoptionDefaults: defaults,
            adoptionFlagKey: flagKey
        )

        // SEC-18: while the legacy global item is unreadable, adoption stays
        // suspended and the same ephemeral token is served on every read.
        let first = store.token
        #expect(store.token == first)
        #expect(defaults.bool(forKey: flagKey) == false)
        #expect(scopedStorage.load() == nil)

        // Once the legacy store becomes readable, the stored legacy identity
        // is adopted and persisted exactly once.
        globalStorage.makeReadable()
        #expect(store.token == legacyToken)
        #expect(scopedStorage.load() == legacyToken)
        #expect(defaults.bool(forKey: flagKey) == true)
    }

    // MARK: - Helpers

    /// Builds a `KeychainTokenStorage` whose reads report the item as present
    /// but unreadable (`errSecInteractionNotAllowed`, SEC-7), with every write
    /// seam recorded so tests can assert the memo never authorizes one.
    private func lockedKeychainStorage(
        service: String = "com.cupthread.test.memo.\(UUID().uuidString)",
        account: String = "account.\(UUID().uuidString)",
        adds: WriteCounter = WriteCounter(),
        updates: WriteCounter = WriteCounter()
    ) -> KeychainTokenStorage {
        KeychainTokenStorage(
            service: service,
            account: account,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            addItem: { _ in
                adds.record()
                return errSecSuccess
            },
            updateItem: { _, _ in
                updates.record()
                return errSecSuccess
            },
            copyItem: { _, _ in errSecInteractionNotAllowed }
        )
    }
}

/// Thread-safe counter for scripted `SecItemAdd`/`SecItemUpdate` seams.
private final class WriteCounter: @unchecked Sendable {
    private let state = NSLock()
    private var total = 0

    /// Whether nothing has been recorded yet.
    var isEmpty: Bool {
        state.lock()
        defer { state.unlock() }
        return total == 0
    }

    func record() {
        state.lock()
        defer { state.unlock() }
        total += 1
    }
}

/// Storage double that toggles between a locked read (SEC-7) and a readable
/// stored identity, recording every write attempt.
private final class GatedTokenStorage: TokenStorage, @unchecked Sendable {
    private let state = NSLock()
    private let storedToken: String
    private var readable = false
    private var writes = 0

    init(storedToken: String) {
        self.storedToken = storedToken
    }

    /// Every write attempt observed, accepted or not.
    var writeAttempts: Int {
        state.lock()
        defer { state.unlock() }
        return writes
    }

    /// Presents the backing item as present but unreadable (SEC-7).
    func makeUnreadable() {
        state.lock()
        defer { state.unlock() }
        readable = false
    }

    /// Presents the stored identity as readable.
    func makeReadable() {
        state.lock()
        defer { state.unlock() }
        readable = true
    }

    func load() -> String? {
        if case .found(let token) = loadResult() { return token }
        return nil
    }

    func loadResult() -> TokenLoadResult {
        state.lock()
        defer { state.unlock() }
        if readable {
            return .found(storedToken)
        }
        return .inaccessible(errSecInteractionNotAllowed)
    }

    func save(_ token: String) {
        recordWrite()
    }

    @discardableResult
    func saveConfirmed(_ token: String) -> Bool {
        recordWrite()
        return false
    }

    func delete() {}

    private func recordWrite() {
        state.lock()
        defer { state.unlock() }
        writes += 1
    }
}

/// Storage double whose reads verifiably report "no token stored" but whose
/// writes fail until confirmed writes are allowed, modelling a Keychain that
/// accepts no writes (unprovisioned macOS host, SEC-33 / SEC-13).
private final class UnconfirmedWriteTokenStorage: TokenStorage, @unchecked Sendable {
    private let state = NSLock()
    private var stored: String?
    private var attempts: [String] = []
    private var accepted: [String] = []
    private var confirmWrites = false

    /// The value every write attempt carried, in order.
    var writeAttempts: [String] {
        state.lock()
        defer { state.unlock() }
        return attempts
    }

    /// The values of write attempts that reported success, in order.
    var acceptedTokens: [String] {
        state.lock()
        defer { state.unlock() }
        return accepted
    }

    func allowConfirmedWrites() {
        state.lock()
        defer { state.unlock() }
        confirmWrites = true
    }

    func rejectConfirmedWrites() {
        state.lock()
        defer { state.unlock() }
        confirmWrites = false
    }

    func load() -> String? {
        state.lock()
        defer { state.unlock() }
        return stored
    }

    func save(_ token: String) {
        recordAttempt(token)
    }

    @discardableResult
    func saveConfirmed(_ token: String) -> Bool {
        recordAttempt(token)
        state.lock()
        defer { state.unlock() }
        guard confirmWrites else { return false }
        stored = token
        accepted.append(token)
        return true
    }

    func delete() {
        state.lock()
        defer { state.unlock() }
        stored = nil
    }

    private func recordAttempt(_ token: String) {
        state.lock()
        defer { state.unlock() }
        attempts.append(token)
    }
}
