import Foundation
import Security
import Testing
@testable import CupThreadFeedback

/// Regression coverage for SEC-7 (#209): a Keychain read that fails — locked
/// before first unlock, a transient Security-layer status, or success with
/// contents that cannot be decoded — must never read back as "no token
/// stored", and `UserTokenStore` must not attempt any write behind an item
/// it could not read, because the confirmed write path
/// (`errSecDuplicateItem` → `SecItemUpdate`) would permanently replace the
/// stored end-user identity with a freshly minted UUID.
@Suite("Keychain Inaccessible Reads (SEC-7)")
struct KeychainInaccessibleReadTests {

    @Test func loadResultRoundTripsThroughRealKeychain() throws {
        let testService = "com.cupthread.test.loadresult.\(UUID().uuidString)"
        let testAccount = "account.\(UUID().uuidString)"
        let storage = KeychainTokenStorage(service: testService, account: testAccount)
        defer { storage.delete() }

        // No item stored: a confirmed absence.
        #expect(storage.loadResult() == .notFound)

        let token = UUID().uuidString
        #expect(storage.saveConfirmed(token))
        #expect(storage.loadResult() == .found(token))

        storage.delete()
        #expect(storage.loadResult() == .notFound)
    }

    @Test func loadResultClassifiesItemNotFoundAsAbsent() {
        let storage = scriptedCopyKeychainStorage { errSecItemNotFound }

        #expect(storage.loadResult() == .notFound)
        #expect(storage.load() == nil)
    }

    @Test func loadResultClassifiesLockedKeychainAsInaccessible() {
        let storage = scriptedCopyKeychainStorage { errSecInteractionNotAllowed }

        // A locked Keychain (before first unlock) must not read back as
        // "no token stored" (SEC-7).
        #expect(storage.loadResult() == .inaccessible(errSecInteractionNotAllowed))
        #expect(storage.load() == nil)
    }

    @Test func loadResultClassifiesTransientStatusesAsInaccessible() {
        let storage = scriptedCopyKeychainStorage { errSecMissingEntitlement }

        #expect(storage.loadResult() == .inaccessible(errSecMissingEntitlement))
        #expect(storage.load() == nil)
    }

    @Test func loadResultClassifiesUndecodableContentsAsInaccessible() {
        let corrupted = Data([0xFF, 0xFE, 0xFD])
        let storage = scriptedCopyKeychainStorage { errSecSuccess } data: { corrupted }

        // Success with contents that are not a non-empty UTF-8 string still
        // means an item exists; it must never read back as absent.
        #expect(storage.loadResult() == .inaccessible(errSecDecode))
        #expect(storage.load() == nil)
    }

    @Test func loadResultTreatsEmptyContentsAsAbsent() {
        let storage = scriptedCopyKeychainStorage { errSecSuccess } data: { Data() }

        // An item holding an empty value carries no identity, so it reads
        // back as a confirmed absence like the legacy `load()` behavior.
        #expect(storage.loadResult() == .notFound)
        #expect(storage.load() == nil)
    }

    @Test func tokenDoesNotOverwriteIdentityWhenKeychainIsLocked() {
        let adds = WriteCounter()
        let updates = WriteCounter()

        // The exact hazard from SEC-7: the item cannot be read back
        // (locked), yet a write would silently succeed through the
        // duplicate-item path and rotate the stored identity.
        let storage = KeychainTokenStorage(
            service: "com.cupthread.test.sec7.\(UUID().uuidString)",
            account: "account.\(UUID().uuidString)",
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            addItem: { _ in
                adds.record()
                return errSecDuplicateItem
            },
            updateItem: { _, _ in
                updates.record()
                return errSecSuccess
            },
            copyItem: { _, _ in errSecInteractionNotAllowed }
        )
        let store = UserTokenStore(storage: storage, legacyUserDefaults: nil, legacyKey: nil)

        let first = store.token
        #expect(!first.isEmpty)
        #expect(UUID(uuidString: first) != nil)

        // Nothing may be attempted against the unreadable item, and nothing
        // is persisted: the next read mints another throwaway instead of
        // re-serving a token that exists nowhere durable.
        let second = store.token
        #expect(UUID(uuidString: second) != nil)
        #expect(second != first)
        #expect(adds.isEmpty)
        #expect(updates.isEmpty)
    }

    @Test func tokenSkipsAllStorageWritesWhenReadReportsInaccessible() {
        let storage = LockedReadTokenStorage()

        let store = UserTokenStore(storage: storage, legacyUserDefaults: nil, legacyKey: nil)
        let token = store.token

        #expect(!token.isEmpty)
        #expect(UUID(uuidString: token) != nil)
        #expect(storage.writeAttempts == 0)
        #expect(storage.deleteCalls == 0)
    }

    @Test func inaccessibleReadLeavesAdoptionFlagAndLegacyPlaintextUntouched() throws {
        let context = Self.makeIsolatedDefaults()
        defer { context.cleanup() }

        let legacyToken = UUID().uuidString
        let legacyKey = "test.sec7.plaintext.\(UUID().uuidString)"
        let flagKey = "test.sec7.flag.\(UUID().uuidString)"
        context.defaults.set(legacyToken, forKey: legacyKey)

        let storage = LockedReadTokenStorage()
        let store = UserTokenStore(
            storage: storage,
            legacyUserDefaults: context.defaults,
            legacyKey: legacyKey,
            legacyGlobalStore: nil,
            adoptionDefaults: context.defaults,
            adoptionFlagKey: flagKey
        )

        #expect(UUID(uuidString: store.token) != nil)

        // An unreadable store is not an adopted store: the one-shot flag
        // stays unset and the legacy plaintext survives for the retry.
        #expect(context.defaults.bool(forKey: flagKey) == false)
        #expect(context.defaults.string(forKey: legacyKey) == legacyToken)
        #expect(storage.writeAttempts == 0)
    }

    @Test func storedIdentityWinsAfterKeychainBecomesReadableAgain() throws {
        // A stored identity that reads back as locked until the device
        // "unlocks"; afterwards the original token must win over any
        // ephemeral UUID served during the locked window.
        let storedToken = UUID().uuidString
        let gate = UnlockGateTokenStorage(storedToken: storedToken)

        let store = UserTokenStore(storage: gate, legacyUserDefaults: nil, legacyKey: nil)

        let lockedWindowToken = store.token
        #expect(UUID(uuidString: lockedWindowToken) != nil)
        #expect(lockedWindowToken != storedToken)
        #expect(gate.writeAttempts == 0)

        gate.unlock()

        #expect(store.token == storedToken)
        #expect(gate.writeAttempts == 0)
    }

    // MARK: - Helpers

    private struct IsolatedContext {
        let defaults: UserDefaults
        let suiteName: String

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private static func makeIsolatedDefaults() -> IsolatedContext {
        let suiteName = "test.sec7.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return IsolatedContext(defaults: defaults, suiteName: suiteName)
    }

    /// Builds a `KeychainTokenStorage` whose `SecItemCopyMatching` outcome is
    /// scripted, so the SEC-7 read classification is testable without real
    /// Keychain I/O. `data` supplies the payload returned on an
    /// `errSecSuccess` read (defaults to a valid token).
    private func scriptedCopyKeychainStorage(
        status: @escaping @Sendable () -> OSStatus,
        data: @escaping @Sendable () -> Data = { Data(UUID().uuidString.utf8) }
    ) -> KeychainTokenStorage {
        KeychainTokenStorage(
            service: "com.cupthread.test.copyscripted.\(UUID().uuidString)",
            account: "account.\(UUID().uuidString)",
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            addItem: { _ in errSecSuccess },
            updateItem: { _, _ in errSecSuccess },
            copyItem: { _, result in
                let scripted = status()
                guard scripted == errSecSuccess else { return scripted }
                result?.pointee = data() as CFTypeRef
                return errSecSuccess
            }
        )
    }
}

/// Thread-safe counter for scripted `SecItemAdd`/`SecItemUpdate` seams.
private final class WriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0

    /// Whether nothing has been recorded yet.
    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return total == 0
    }

    func record() {
        lock.lock()
        defer { lock.unlock() }
        total += 1
    }
}

/// Storage double whose reads report the item as present but unreadable,
/// standing in for a locked Keychain (`errSecInteractionNotAllowed` before
/// first unlock, SEC-7). Records every write attempt so tests can assert
/// none of them reach the backing store.
private final class LockedReadTokenStorage: TokenStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    private var deletes = 0

    /// Number of write attempts (save/saveConfirmed) observed.
    var writeAttempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    /// Number of delete calls observed.
    var deleteCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return deletes
    }

    func load() -> String? {
        nil
    }

    func loadResult() -> TokenLoadResult {
        .inaccessible(errSecInteractionNotAllowed)
    }

    func save(_ token: String) {
        recordWrite()
    }

    @discardableResult
    func saveConfirmed(_ token: String) -> Bool {
        recordWrite()
        return false
    }

    func delete() {
        lock.lock()
        defer { lock.unlock() }
        deletes += 1
    }

    private func recordWrite() {
        lock.lock()
        defer { lock.unlock() }
        writes += 1
    }
}

/// Storage double modeling an item that exists all along but reads back as
/// locked until ``unlock()`` simulates the device becoming readable, so the
/// identity-survival guarantee across the locked window can be asserted.
private final class UnlockGateTokenStorage: TokenStorage, @unchecked Sendable {
    private let lock = NSLock()
    private let storedToken: String
    private var unlocked = false
    private var writes = 0

    init(storedToken: String) {
        self.storedToken = storedToken
    }

    /// Every write attempt observed, accepted or not.
    var writeAttempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    func unlock() {
        lock.lock()
        defer { lock.unlock() }
        unlocked = true
    }

    func load() -> String? {
        if case .found(let token) = loadResult() { return token }
        return nil
    }

    func loadResult() -> TokenLoadResult {
        lock.lock()
        defer { lock.unlock() }
        if unlocked {
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

    func delete() {
        lock.lock()
        defer { lock.unlock() }
        unlocked = false
    }

    private func recordWrite() {
        lock.lock()
        defer { lock.unlock() }
        writes += 1
    }
}
