import Foundation
import Security
import Testing
@testable import CupThreadFeedback

/// Regression coverage for SEC-33 (#552): `KeychainTokenStorage` must target
/// the data-protection keychain (`kSecUseDataProtectionKeychain`) in every
/// SecItem operation. Without it, macOS routes the calls to the legacy
/// file-based login keychain, whose shim neither upholds
/// `kSecAttrAccessible` semantics nor reliably accepts them (TN3137) —
/// writes fail with `errSecParam` on some configurations or silently land
/// in a keychain that cannot honor the documented device-only guarantee,
/// rotating the anonymous identity on every read.
@Suite("Keychain Data-Protection Targeting (SEC-33)")
struct KeychainDataProtectionTests {

    /// Captures the `CFDictionary` arguments reaching each scripted SecItem
    /// seam so the tests can assert the exact attributes the storage sends.
    private final class SeamCapture: @unchecked Sendable {
        var add: NSDictionary?
        var update: NSDictionary?
        var copy: NSDictionary?
        var delete: NSDictionary?
    }

    @Test func everySecItemOperationTargetsTheDataProtectionKeychain() {
        let capture = SeamCapture()
        let storage = KeychainTokenStorage(
            service: "com.cupthread.test.sec33.\(UUID().uuidString)",
            account: "account.\(UUID().uuidString)",
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            addItem: { attributes in
                capture.add = attributes as NSDictionary
                // Force the duplicate-item path so `SecItemUpdate` runs too.
                return errSecDuplicateItem
            },
            updateItem: { _, changes in
                capture.update = changes as NSDictionary
                return errSecSuccess
            },
            copyItem: { query, _ in
                capture.copy = query as NSDictionary
                return errSecItemNotFound
            },
            deleteItem: { query in
                capture.delete = query as NSDictionary
                return errSecItemNotFound
            }
        )

        // Exercise all four operations: read (copy), write (add + duplicate
        // → update), and delete.
        _ = storage.loadResult()
        #expect(storage.saveConfirmed("sec33-token"))
        #expect(storage.deleteConfirmed())

        let operations: [(String, NSDictionary?)] = [
            ("SecItemCopyMatching (read)", capture.copy),
            ("SecItemAdd (write)", capture.add),
            ("SecItemUpdate (overwrite)", capture.update),
            ("SecItemDelete (delete)", capture.delete)
        ]
        for (name, dictionary) in operations {
            guard let dictionary else {
                Issue.record("\(name) seam was never invoked")
                continue
            }
            #expect(
                dictionary[kSecUseDataProtectionKeychain as String] as? Bool == true,
                "\(name) must target the data-protection keychain (SEC-33)"
            )
        }

        // The device-only accessibility attribute still travels with the
        // write dictionaries alongside the keychain targeting.
        #expect(
            capture.add?[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        #expect(
            capture.update?[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    @Test(.enabled(if: DataProtectionKeychainProbe.isWritable))
    func realDataProtectionKeychainRoundTrips() {
        let storage = KeychainTokenStorage(
            service: "com.cupthread.test.sec33.real.\(UUID().uuidString)",
            account: "account.\(UUID().uuidString)"
        )
        defer { storage.delete() }

        // Starts absent, persists, reads back, and deletes — all against the
        // real data-protection keychain, proving the dictionaries are
        // accepted where the keychain is actually writable (signed hosts).
        #expect(storage.saveConfirmed(UUID().uuidString.lowercased()))
        let stored = storage.loadResult()
        guard case .found(let token) = stored else {
            Issue.record("Expected a readable token after a confirmed write, got \(stored)")
            return
        }
        #expect(UUID(uuidString: token) != nil)
        #expect(storage.deleteConfirmed())
        #expect(storage.loadResult() == .notFound)
    }

    @Test(.enabled(if: !DataProtectionKeychainProbe.isWritable))
    func unprovisionedProcessFailsHonestlyInsteadOfUsingTheFileBasedKeychain() {
        let storage = KeychainTokenStorage(
            service: "com.cupthread.test.sec33.degraded.\(UUID().uuidString)",
            account: "account.\(UUID().uuidString)"
        )

        // An unprovisioned process (unsigned tool, `swift test` host) cannot
        // reach the data-protection keychain. The storage must report that
        // honestly — empty reads, failed writes and deletes — and never
        // silently fall back to the file-based login keychain, which cannot
        // uphold the device-only guarantee (SEC-33).
        #expect(storage.load() == nil)
        #expect(storage.saveConfirmed(UUID().uuidString) == false)
        #expect(storage.deleteConfirmed() == false)
        #expect(storage.load() == nil)
    }

    @Test(.enabled(if: !DataProtectionKeychainProbe.isWritable))
    func userTokenStoreServesEphemeralIdentityWhenDataProtectionKeychainIsUnwritable() {
        let storage = KeychainTokenStorage(
            service: "com.cupthread.test.sec33.store.\(UUID().uuidString)",
            account: "account.\(UUID().uuidString)"
        )
        let store = UserTokenStore(storage: storage, legacyUserDefaults: nil, legacyKey: nil)

        // The documented fallback: a valid identity is served for the read,
        // but the unconfirmed write persists nothing, so no durable identity
        // is created outside the data-protection keychain.
        #expect(UUID(uuidString: store.token) != nil)
        #expect(storage.load() == nil)
    }
}
