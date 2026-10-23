import Foundation
import Testing
@testable import CupThreadFeedback

/// Regression coverage for issue #511: minted anonymous identities use the
/// canonical lowercase spelling the server stores after HMAC verification,
/// while identities already persisted keep their original spelling.
@Suite("UserTokenStore token spelling")
struct UserTokenSpellingTests {

    @Test func preExistingUppercaseTokenKeepsItsSpelling() throws {
        let suiteName = "test.tokenspelling.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let testKey = "test.token.\(UUID().uuidString)"
        let existingUppercase = UUID().uuidString
        #expect(existingUppercase != existingUppercase.lowercased())
        defaults.set(existingUppercase, forKey: testKey)

        let store = UserTokenStore(userDefaults: defaults, key: testKey)

        // Stored identities are served byte-for-byte; canonicalizing the
        // spelling only applies to tokens this store mints (issue #511).
        #expect(store.token == existingUppercase)
        #expect(defaults.string(forKey: testKey) == existingUppercase)
    }

    @Test func freshlyMintedTokenIsLowercaseUUID() throws {
        let storage = RecordingTokenStorage()
        let store = UserTokenStore(storage: storage, legacyUserDefaults: nil, legacyKey: nil)

        let token = store.token

        #expect(token == token.lowercased())
        #expect(token.count == 36)
        #expect(UUID(uuidString: token) != nil)
        #expect(storage.load() == token)
        // Re-reading the persisted identity never re-mints or re-cases it.
        #expect(store.token == token)
    }

    @Test func unconfirmedWriteServesLowercaseEphemeralToken() throws {
        let store = UserTokenStore(
            storage: UnwritableTokenStorage(),
            legacyUserDefaults: nil,
            legacyKey: nil
        )

        let token = store.token

        #expect(token == token.lowercased())
        #expect(UUID(uuidString: token) != nil)
    }

    @Test func inaccessibleReadServesLowercaseEphemeralToken() throws {
        let store = UserTokenStore(
            storage: UnreadableTokenStorage(),
            legacyUserDefaults: nil,
            legacyKey: nil
        )

        let token = store.token

        #expect(token == token.lowercased())
        #expect(UUID(uuidString: token) != nil)
    }
}

/// A minimal in-memory store that exposes what was persisted.
private final class RecordingTokenStorage: TokenStorage, @unchecked Sendable {
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

/// A store that always reports "no token" but rejects every write, modelling
/// a Keychain that cannot confirm persistence (the ephemeral-token path).
private final class UnwritableTokenStorage: TokenStorage, @unchecked Sendable {
    func load() -> String? { nil }

    func save(_ token: String) {}

    func saveConfirmed(_ token: String) -> Bool { false }

    func delete() {}
}

/// A store whose read cannot be confirmed, modelling a locked Keychain
/// before first unlock (SEC-7). It must never be written behind.
private final class UnreadableTokenStorage: TokenStorage, @unchecked Sendable {
    func load() -> String? { nil }

    func loadResult() -> TokenLoadResult { .inaccessible(errSecInteractionNotAllowed) }

    func save(_ token: String) {}

    func saveConfirmed(_ token: String) -> Bool { false }

    func delete() {}
}
