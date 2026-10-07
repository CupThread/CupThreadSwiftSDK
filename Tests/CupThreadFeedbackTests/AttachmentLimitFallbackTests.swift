import Foundation
import ImageIO
import Testing
@testable import CupThreadFeedback

/// Regression coverage for issue #287: a failed config read must not
/// silently roll the composer's effective attachment limit back to the
/// compiled-in 20 MB default. The last-known console limit persists on disk
/// and keeps the #52 automatic downscale path matched to the server-side
/// limit through config outages.
@Suite("AttachmentLimitFallback")
struct AttachmentLimitFallbackTests {
    private let appKey = "app_attachment_limit_fallback"

    // MARK: - Cache round-trip (#287 requirement 1)

    @Test func cacheRoundTripsAppearanceAndAttachmentLimit() {
        let storage = InMemoryAttachmentLimitStorage()
        let cache = SdkConfigCache(appKey: appKey, storage: storage)
        let appearance = SdkAppearance(theme: .forest)

        cache.store(appearance: appearance, maxAttachmentBytes: 5_000_000)

        #expect(cache.cachedAppearance() == appearance)
        #expect(cache.cachedMaxAttachmentBytes() == 5_000_000)
    }

    @Test func cacheOverwritesPreviousLimitOnEverySuccessfulStore() {
        let storage = InMemoryAttachmentLimitStorage()
        let cache = SdkConfigCache(appKey: appKey, storage: storage)

        cache.store(appearance: SdkAppearance(theme: .ocean), maxAttachmentBytes: 5_000_000)
        cache.store(appearance: SdkAppearance(theme: .midnight), maxAttachmentBytes: 30_000_000)

        #expect(cache.cachedAppearance()?.theme == .midnight)
        #expect(cache.cachedMaxAttachmentBytes() == 30_000_000)
    }

    @Test func legacyCachePayloadDecodesAppearanceWithUnknownLimit() throws {
        // A payload written by an SDK version that cached the bare
        // appearance: the appearance stays recoverable, the limit is
        // unknown — never a bogus default.
        let storage = InMemoryAttachmentLimitStorage()
        let cache = SdkConfigCache(appKey: appKey, storage: storage)
        let legacyAppearance = SdkAppearance(theme: .candy)
        storage.set(try JSONEncoder().encode(legacyAppearance), forKey: SdkConfigCache.keyPrefix + appKey)

        #expect(cache.cachedAppearance() == legacyAppearance)
        #expect(cache.cachedMaxAttachmentBytes() == nil)
    }

    @Test func corruptedCachePayloadDecodesAsNothingCached() {
        let storage = InMemoryAttachmentLimitStorage()
        let cache = SdkConfigCache(appKey: appKey, storage: storage)
        storage.set(Data("not json".utf8), forKey: SdkConfigCache.keyPrefix + appKey)

        #expect(cache.cachedAppearance() == nil)
        #expect(cache.cachedMaxAttachmentBytes() == nil)
    }

    @Test func emptyCacheDecodesAsNothingCached() {
        let cache = SdkConfigCache(appKey: appKey, storage: InMemoryAttachmentLimitStorage())

        #expect(cache.cachedAppearance() == nil)
        #expect(cache.cachedMaxAttachmentBytes() == nil)
    }

    // MARK: - Fallback priority (#287 requirement 2)

    @Test func resolveAttachmentLimitPrefersSuppliedConfigOverEverythingElse() {
        let supplied = makeConfig(maxAttachmentBytes: 8_000_000)

        let resolved = FeedbackComposerAttachmentLimit.resolve(
            config: supplied,
            lastKnownLimit: 5_000_000
        )

        #expect(resolved == 8_000_000)
    }

    @Test func resolveAttachmentLimitUsesFetchedConsoleLimit() {
        let fetched = makeConfig(maxAttachmentBytes: 30_000_000)

        let resolved = FeedbackComposerAttachmentLimit.resolve(
            config: fetched,
            lastKnownLimit: nil
        )

        #expect(resolved == 30_000_000)
    }

    @Test func resolveAttachmentLimitFallsBackToLastKnownLimitOnFailedRead() {
        let resolved = FeedbackComposerAttachmentLimit.resolve(
            config: nil,
            lastKnownLimit: 5_000_000
        )

        #expect(resolved == 5_000_000)
    }

    @Test func resolveAttachmentLimitReturnsNilOnFirstRunWithNoCache() {
        let resolved = FeedbackComposerAttachmentLimit.resolve(
            config: nil,
            lastKnownLimit: nil
        )

        #expect(resolved == nil, "Nothing resolved must leave the compiled-in default in force")
    }

    // MARK: - Downscale contract through the fallback (#287 requirement 3)

    @Test func lastKnownLimitDrivesDownscaleOfOversizedPhoto() async throws {
        // What the composer does on a failed config read: apply the
        // last-known console limit, then prepare an oversized photo through
        // the state machine's limit — the #52 contract must keep working.
        let lastKnownLimit = 5_000_000
        let oversized = try #require(makeOversizedJPEGFixture())
        try #require(oversized.count > lastKnownLimit, "Fixture must exceed the last-known limit")

        var machine = FeedbackAttachmentStateMachine(maxAttachmentBytes: nil)
        #expect(machine.maxAttachmentBytes == PhotoAttachmentHelper.defaultMaxAttachmentBytes)
        let applied = machine.applyConfigLimit(lastKnownLimit)
        #expect(applied)
        #expect(machine.maxAttachmentBytes == lastKnownLimit)

        let prepared = try await PhotoAttachmentHelper.prepareForUpload(
            oversized,
            limit: machine.maxAttachmentBytes,
            stripSensitiveMetadata: false
        )

        #expect(prepared.data.count <= lastKnownLimit)
        #expect(prepared.data.count < oversized.count, "The photo must be downscaled, not returned as-is")
    }

    // MARK: - Regression: successful fetch still applies its limit (#287 requirement 4)

    @Test func fetchedConfigLimitBeatsStaleLastKnownLimit() {
        // A successful read must apply the fresh console value, not the
        // persisted one from an earlier session.
        let fetched = makeConfig(maxAttachmentBytes: 30_000_000)

        let resolved = FeedbackComposerAttachmentLimit.resolve(
            config: fetched,
            lastKnownLimit: 5_000_000
        )

        #expect(resolved == 30_000_000)
    }

    // MARK: - Helpers

    private func makeConfig(maxAttachmentBytes: Int) -> PublicAppConfig {
        PublicAppConfig(
            appId: "app-1",
            appKey: appKey,
            slug: "demo-app",
            name: "Demo App",
            maxAttachmentBytes: maxAttachmentBytes
        )
    }

    /// A noisy JPEG whose original encoding exceeds a 5 MB limit while its
    /// quality-stepped downscale fits inside it (random noise keeps the
    /// original large, and the encode floor compresses the capped bitmap
    /// below the limit — the same deterministic recipe as the #52 suite).
    private func makeOversizedJPEGFixture() -> Data? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: nil,
            width: 4_000,
            height: 1_600,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }
        guard let buffer = context.data else { return nil }
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * 1_600)
        for row in 0..<1_600 {
            let rowStart = row * context.bytesPerRow
            for column in 0..<(4_000 * 4) {
                pixels[rowStart + column] = UInt8.random(in: 0...255)
            }
        }
        guard let image = context.makeImage() else { return nil }
        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            outputData as CFMutableData,
            "public.jpeg" as CFString,
            1,
            nil
        ) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return outputData as Data
    }
}

/// In-memory ``SdkConfigCacheStorage`` so cache tests are independent of the
/// process-wide `UserDefaults`.
private final class InMemoryAttachmentLimitStorage: SdkConfigCacheStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ data: Data, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = data
    }
}
