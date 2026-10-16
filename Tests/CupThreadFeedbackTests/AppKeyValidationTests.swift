import Foundation
import Testing
@testable import CupThreadFeedback

// Regression tests for #420 (SEC-22): the app key is security-sensitive
// input — it is interpolated into endpoint paths, query items, the Turnstile
// `cdata` binding, HMAC canonical lines, and scoped storage identities. The
// configuration trims surrounding whitespace, every dispatch funnels through
// `applyCorrelationHeaders`, which rejects grammar violations before any
// network round trip, and scoped-storage keys normalize the same way so a
// padded value can never mint an alias identity.

// MARK: - Grammar

@Suite("AppKeyGrammar")
struct AppKeyGrammarTests {
    @Test("Console-issued keys match the grammar")
    func validKeys() {
        for key in ["a", "app_1", "app_live_12345", "App.Name-9", "app_x.9_y-z",
                    String(repeating: "a", count: 64)] {
            #expect(AppKeyGrammar.isValid(key), "'\(key)' should be valid")
        }
    }

    @Test("Blank, traversal, separator, control, and oversize keys are rejected")
    func invalidKeys() {
        for key in ["", " ", "   ", " \n\t ",
                    "..", "...", "../admin", "app/../admin", "app/sub", "app\\sub",
                    "app\\\\test", "app key", "app\nkey", "app\rkey", "app\u{7}key",
                    "app\u{00A0}key", "ключ", String(repeating: "a", count: 65)] {
            #expect(!AppKeyGrammar.isValid(key), "'\(key)' should be invalid")
        }
    }

    @Test("Normalization trims surrounding whitespace")
    func normalizedTrims() {
        #expect(AppKeyGrammar.normalized("  app_live_12345  ") == "app_live_12345")
        #expect(AppKeyGrammar.normalized(" \n\t app_1 \t\n ") == "app_1")
        #expect(AppKeyGrammar.normalized("app_1") == "app_1")
        #expect(AppKeyGrammar.normalized("   ").isEmpty)
    }
}

// MARK: - Configuration normalization

@Suite("AppKeyConfigurationNormalization")
struct AppKeyConfigurationNormalizationTests {
    @Test("Whitespace-padded appKey is trimmed at init (#420)")
    func paddedAppKeyIsTrimmed() {
        let config = FeedbackClientConfiguration(
            baseURL: URL(string: "https://api.cupthread.com")!,
            appKey: "  app_live_12345  "
        )
        #expect(config.appKey == "app_live_12345")
    }

    @Test("A trimmed key is untouched; equality is by normalized value")
    func equalityUsesNormalizedValue() {
        let base = URL(string: "https://api.cupthread.com")!
        #expect(
            FeedbackClientConfiguration(baseURL: base, appKey: "app_1")
                == FeedbackClientConfiguration(baseURL: base, appKey: "  app_1  ")
        )
    }
}

// MARK: - Dispatch rejection

@Suite("AppKeyDispatchValidation", .serialized)
struct AppKeyDispatchValidationTests {
    static let apiHost = "appkey-validation.example.com"

    static func makeValidatedClient(appKey: String) -> FeedbackClient {
        makeClient(
            baseURL: URL(string: "https://\(apiHost)")!,
            appKey: appKey
        )
    }

    static func stubSuccess(_ capture: CaptureBox<URLRequest>) {
        MockURLProtocol.setHandler(forHost: apiHost) { request in
            capture.value = request
            return (makeHTTPResponse(), try encodeJSON(makeConfigJSON()))
        }
    }

    @Test("Invalid app keys throw invalidConfiguration before any network round trip")
    func invalidAppKeysNeverReachTheNetwork() async throws {
        for appKey in ["", "   ", "../admin", "app/sub", "app\\sub"] {
            let capture = CaptureBox<URLRequest>()
            Self.stubSuccess(capture)

            let client = Self.makeValidatedClient(appKey: appKey)

            await #expect(throws: FeedbackClientError.invalidConfiguration(message:
                "configuration.appKey is blank or violates the app-key grammar " +
                "^[A-Za-z0-9_.-]{1,64}$; no request was sent"
            )) {
                try await client.fetchAppConfig()
            }
            #expect(capture.value == nil, "no request may be built for appKey '\(appKey)'")
        }
    }

    @Test("Every client funnel validates the app key before dispatch")
    func everyFunnelValidatesBeforeDispatch() async {
        for appKey in ["", "../admin"] {
            let client = Self.makeValidatedClient(appKey: appKey)
            let draft = FeedbackDraft(title: "t", description: "d", platform: .ios)

            await #expect(throws: FeedbackClientError.self) {
                try await client.fetchAppConfig()
            }
            await #expect(throws: FeedbackClientError.self) {
                try await client.fetchVersions()
            }
            await #expect(throws: FeedbackClientError.self) {
                try await client.fetchFeatureRequests(userToken: "tok")
            }
            await #expect(throws: FeedbackClientError.self) {
                try await client.submit(draft)
            }
            await #expect(throws: FeedbackClientError.self) {
                try await client.subscribeToChangelog(email: "a@b.co", userToken: "tok")
            }
            await #expect(throws: FeedbackClientError.self) {
                try await client.updateUserAttributes(isPaying: false, userToken: "tok")
            }
        }
    }

    @Test("The thrown error carries the grammar diagnostic, no request id, and localized copy")
    func errorCarriesDiagnosticWithoutRequestId() async {
        let client = Self.makeValidatedClient(appKey: "../admin")
        do {
            _ = try await client.fetchAppConfig()
            Issue.record("expected invalidConfiguration")
        } catch let error as FeedbackClientError {
            guard case .invalidConfiguration(let message) = error else {
                Issue.record("expected .invalidConfiguration, got \(error)")
                return
            }
            #expect(message.contains("app-key grammar"))
            #expect(!message.contains("../admin"), "the raw key never belongs in diagnostics")
            #expect(error.requestId == nil)
            #expect(error.errorDescription?.isEmpty == false)
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }

    @Test("A padded but valid key dispatches with its trimmed form in the path")
    func paddedValidKeyDispatchesTrimmed() async throws {
        let capture = CaptureBox<URLRequest>()
        Self.stubSuccess(capture)

        let client = Self.makeValidatedClient(appKey: "  app_testkey123456  ")
        _ = try await client.fetchAppConfig()

        let request = try #require(capture.value)
        #expect(request.url?.path.contains("/api/v1/public/config/app_testkey123456") == true)
    }
}

// MARK: - Scoped storage normalization

@Suite("AppKeyScopedStorage")
struct AppKeyScopedStorageTests {
    @Test("UserTokenStore scoped keys and adoption flags trim identically")
    func userTokenStoreKeysTrim() {
        #expect(
            UserTokenStore.scopedKey(for: "  app_x  ") == UserTokenStore.scopedKey(for: "app_x")
        )
        #expect(UserTokenStore.scopedKey(for: "  app_x  ") == "com.cupthread.featureRequestUserToken.app_x")
        #expect(
            UserTokenStore.legacyAdoptionFlagKey(for: "  app_x  ")
                == UserTokenStore.legacyAdoptionFlagKey(for: "app_x")
        )
        #expect(
            UserTokenStore.scopedKey(for: "app_x")
                == UserTokenStore.scopedKey(for: "app_x").trimmingCharacters(in: .whitespaces)
        )
    }

    @Test("ChangelogSubscriptionStore trims the storage namespace")
    func subscriptionStoreTrims() {
        let padded = ChangelogSubscriptionStore(appKey: "  app_x  ")
        let clean = ChangelogSubscriptionStore(appKey: "app_x")
        #expect(padded.storageKey == clean.storageKey)
        #expect(padded.appKey == "app_x")
        #expect(padded.storageKey == "com.cupthread.changelog.subscribedEmail.app_x")
    }

    @Test("ChangelogSeenStore trims the storage namespace and registry key")
    func seenStoreTrims() {
        ChangelogSeenStore.resetRegistry()
        defer { ChangelogSeenStore.resetRegistry() }

        #expect(
            ChangelogSeenStore.shared(for: "  app_x  ") === ChangelogSeenStore.shared(for: "app_x")
        )

        let suiteName = "test.appkeyscoped.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let padded = ChangelogSeenStore(appKey: "  app_y  ", userDefaults: defaults)
        let clean = ChangelogSeenStore(appKey: "app_y", userDefaults: defaults)
        #expect(padded.storageKey == clean.storageKey)
        #expect(padded.storageKey == "com.cupthread.changelog.seenVersions.app_y")
    }

    @Test("SdkConfigCache reads the same entry through a padded key")
    func configCacheTrims() {
        let clean = SdkConfigCache(appKey: "app_cache")
        let padded = SdkConfigCache(appKey: "  app_cache  ")
        clean.store(appearance: .defaults, maxAttachmentBytes: 1_234)
        #expect(padded.cachedAppearance() != nil)
        #expect(padded.cachedMaxAttachmentBytes() == 1_234)
    }
}
