// swiftlint:disable file_length
// One loader per file: the bounded-decode and cookie-isolation policies are
// documented beside the code that enforces them, the same policy the other
// oversized files follow (.swiftlint.yml).
import SwiftUI
import ImageIO
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Platform image

#if canImport(UIKit)
/// Decoded bitmap type cached by `RemoteImageLoader` on UIKit platforms.
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
/// Decoded bitmap type cached by `RemoteImageLoader` on macOS.
typealias PlatformImage = NSImage
#endif

// MARK: - Loader

/// Shared loader for remote images (avatars, app icons).
///
/// `AsyncImage` downloads through an ephemeral session with no caching and no
/// in-flight de-duplication, so every `Lazy*` cell re-creation re-downloads the
/// same URL and flashes its placeholder. The loader instead keeps decoded
/// images in an `NSCache` and coalesces concurrent requests for one URL into a
/// single download. Failures are remembered in a short-lived negative cache:
/// a URL that just failed replays its error without contacting the network
/// until `failureRetryInterval` elapses, so a permanently dead avatar or icon
/// is not re-requested on every scroll re-appearance, while a transient outage
/// recovers automatically once the window lapses.
///
/// The memory profile is bounded rather than source-dependent: decode runs
/// through an ImageIO thumbnail pass with a pixel-edge cap (avatars and icons
/// render at 16–80 pt, so full-resolution sources are pure waste), the
/// response body is consumed incrementally and the download is cancelled as
/// soon as it exceeds a byte cap, and the cache enforces a byte budget charged
/// with each decoded bitmap's size in addition to its entry count.
///
/// The transfer stays on the validated URL's origin for its whole lifetime:
/// a redirect is followed only when it remains `https` on the same host and
/// effective port, so a 30x cannot pivot an avatar/icon fetch off-origin or
/// downgrade it to plaintext (SEC-31).
///
/// Public image delivery URLs (such as `https://api.cupthread.com/api/v1/files/{key}`)
/// are handled as opaque URLs, preserving the path and query string (such as `?width=...`).
/// Distinct thumbnail width hints are partitioned as separate cache entries in `NSCache`.
/// Format decoding evaluates container data via ImageIO (e.g. WebP thumbnails or original bytes)
/// rather than inferring formats from URL file extensions.
///
/// MainActor-isolated so cached images are only touched from one isolation
/// domain; the download itself (including bitmap decoding) runs detached to
/// keep that work off the main thread.
@MainActor
final class RemoteImageLoader {
    /// Process-wide loader used by `CachedRemoteImage`.
    static let shared = RemoteImageLoader()

    /// A download failure worth replaying inside the negative-cache window.
    private struct FailedFetch {
        let date: Date
        let error: any Error
    }

    private let session: URLSession
    private let bodyTransport: BoundedBodyTransport
    private let cache = NSCache<NSURL, PlatformImage>()
    private let failureRetryInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let maxDecodedPixelEdge: CGFloat
    private let maxResponseBytes: Int
    private var inFlight: [URL: Task<PlatformImage, Error>] = [:]
    private var recentFailures: [URL: FailedFetch] = [:]

    /// - Parameters:
    ///   - session: Session used for downloads; inject a test session to
    ///     intercept requests. The loader rebuilds the session around its own
    ///     delegate, and that delegate owns the image path's redirect policy:
    ///     URLSession cannot compose delegates, so a limiter installed on the
    ///     injected session does not carry over, and hosts do not need to
    ///     install one for image fetches. The rebuilt session is always
    ///     cookie-isolated (#585) — automatic `Cookie` headers are disabled
    ///     and the session gets a private, empty `HTTPCookieStorage`, so
    ///     image fetches neither attach the host's ambient cookies nor store
    ///     API `Set-Cookie` responses in the shared jar — regardless of the
    ///     injected session's own cookie policy.
    ///   - cacheCountLimit: Maximum number of decoded images retained.
    ///   - cacheCostLimit: Byte budget for the decoded bitmaps retained in
    ///     the cache; each entry is charged its decoded bitmap size, so the
    ///     budget is deterministic once decode is pixel-bounded.
    ///   - maxDecodedPixelEdge: Cap for the decoded bitmap's longest pixel
    ///     edge; comfortably above the largest consumer (80 pt @3x = 240 px)
    ///     with headroom for future surfaces. Small sources are never
    ///     upscaled.
    ///   - maxResponseBytes: Maximum body size accepted for decode, enforced
    ///     on the bytes the transport delivers (after HTTP content decoding):
    ///     crossing the cap cancels the download instead of buffering the
    ///     whole body first. Larger bodies throw
    ///     `URLError(.cannotDecodeContentData)` without being cached.
    ///   - failureRetryInterval: How long a failed fetch is remembered before
    ///     the URL becomes eligible for a new download attempt.
    ///   - now: Clock used for the negative-cache window; inject for tests.
    init(
        session: URLSession = .shared,
        cacheCountLimit: Int = 500,
        cacheCostLimit: Int = RemoteImageLoader.defaultCacheCostLimit,
        maxDecodedPixelEdge: CGFloat = RemoteImageLoader.defaultMaxDecodedPixelEdge,
        maxResponseBytes: Int = RemoteImageLoader.defaultMaxResponseBytes,
        failureRetryInterval: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let transport = BoundedBodyTransport()
        self.bodyTransport = transport
        // The delegate-backed session shares the injected session's
        // configuration (protocol classes, timeouts, cache policy) so tests
        // and hosts keep intercepting requests, while giving the transport the
        // delegate callbacks it needs to enforce the byte cap mid-transfer.
        // `session.configuration` is a copy, so the cookie isolation below
        // never touches the session the host injected. Image fetches run on
        // the shared session by default, which would otherwise attach ambient
        // host cookies to image requests and persist API `Set-Cookie`
        // responses into the host app's shared cookie jar; the SDK reads no
        // cookies, so the rebuilt session gets its own empty jar and
        // automatic cookie handling disabled (#585).
        let configuration = session.configuration
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = HTTPCookieStorage()
        self.session = URLSession(
            configuration: configuration,
            delegate: transport,
            delegateQueue: nil
        )
        self.failureRetryInterval = failureRetryInterval
        self.now = now
        cache.countLimit = cacheCountLimit
        cache.totalCostLimit = cacheCostLimit
        self.maxDecodedPixelEdge = maxDecodedPixelEdge
        self.maxResponseBytes = maxResponseBytes
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Returns the decoded image for `url`, downloading it at most once per
    /// cache lifetime. Concurrent callers for the same URL share one download.
    ///
    /// URLs are validated against `isAllowedSecureImageURL(_:)`; non-HTTPS or disallowed schemes
    /// (`http:`, `file:`, `data:`, `javascript:`, etc.) immediately throw `URLError(.badURL)`
    /// without contacting the network or consulting the cache. The HTTPS-only
    /// rule applies to redirects too: a 3xx is followed only within the initial
    /// URL's HTTPS origin. A refused redirect surfaces
    /// `URLError(.badServerResponse)` without reaching the target, and a final
    /// response from another origin is rejected as `URLError(.badURL)`.
    ///
/// A download that fails is remembered for `failureRetryInterval`; calls
/// inside that window rethrow the recorded error without a network request.
///
/// Memory is bounded end to end: the decoded bitmap's longest pixel edge is
/// capped at `maxDecodedPixelEdge` via an ImageIO thumbnail decode (avatars
/// and icons render at 16–80 pt), the response body is streamed and the
/// download cancelled as soon as it exceeds `maxResponseBytes`, and the cache
/// carries a byte budget (`cacheCostLimit`, charged with each image's decoded
/// bitmap size) on top of the entry-count limit — so a server-controlled
/// oversized avatar can neither spike transfer memory, spike decode memory,
/// nor accumulate unbounded retained bitmaps.
func image(for url: URL) async throws -> PlatformImage {
        guard isAllowedSecureImageURL(url) else {
            throw URLError(.badURL)
        }
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }
        if let failure = recentFailure(for: url) {
            throw failure.error
        }
        if let existing = inFlight[url] {
            return try await awaitJoinedTask(existing)
        }

        // Detached so decode happens off the MainActor. Deliberately not
        // cancelled when a subscriber goes away: the image lands in the cache
        // either way, so the next appearance resolves instantly (issue #174).
        // Completion handling (cache storage and in-flight cleanup) is owned by
        // the detached task so caller cancellation never drops cache warming or
        // prematurely clears the in-flight coalescing entry.
        let task: Task<PlatformImage, Error> = Task.detached { [session, bodyTransport, maxResponseBytes, maxDecodedPixelEdge, weak self] in
            do {
                let data = try await bodyTransport.fetch(
                    url,
                    using: session,
                    maxBytes: maxResponseBytes
                )
                let image = try Self.decodeBoundedImage(from: data, maxPixelEdge: maxDecodedPixelEdge)
                // A stored entry with a zero cost would escape the byte
                // budget, so refuse it instead of caching it for free.
                guard let cost = Self.storableCacheCost(of: image) else {
                    throw URLError(.cannotDecodeContentData)
                }
                await self?.recordCompletedImage(image, cost: cost, for: url)
                return image
            } catch {
                await self?.recordCompletedFailure(error, for: url)
                throw error
            }
        }
        inFlight[url] = task

        return try await awaitJoinedTask(task)
    }

    /// Number of URLs currently remembered as recently failed; internal so
    /// tests can assert the ledger stays bounded.
    var recentFailureCount: Int { recentFailures.count }

    /// Whether the rebuilt session refuses automatic cookie attachment;
    /// internal so tests can pin the cookie isolation of #585 directly —
    /// a `URLProtocol`-captured request cannot prove the absence of cookie
    /// handling, because Foundation's cookie machinery does not fully
    /// engage behind a custom protocol.
    var sessionDisablesAutomaticCookies: Bool {
        !session.configuration.httpShouldSetCookies
    }

    /// Whether the rebuilt session carries a private cookie jar instead of
    /// the host app's shared storage; internal so tests can pin the inbound
    /// half of the #585 isolation the same way.
    var sessionUsesAPrivateCookieJar: Bool {
        session.configuration.httpCookieStorage !== HTTPCookieStorage.shared
    }

    /// Number of downloads currently in flight; internal so tests can verify
    /// background task completion and table cleanup.
    var inFlightCount: Int { inFlight.count }

    /// Largest number of response bytes buffered at once; internal so tests
    /// can assert the transfer bound, not just the thrown error.
    var peakBufferedBodyBytes: Int { bodyTransport.peakBufferedByteCount }

    /// The cached image for `url`, if any; internal so tests can inspect the
    /// cache without going back through the network path.
    func cachedImageIfPresent(for url: URL) -> PlatformImage? {
        cache.object(forKey: url as NSURL)
    }

    // MARK: Bounded decode and cache cost

    /// Default cap for the decoded bitmap's longest pixel edge: the largest
    /// consumer renders at 80 pt (240 px @3x), so 600 leaves headroom for
    /// future surfaces while keeping per-entry cost small and deterministic
    /// (~1.4 MB for a 600×600 RGBA bitmap).
    nonisolated static let defaultMaxDecodedPixelEdge: CGFloat = 600

    /// Default byte budget for the decoded-bitmap cache (128 MB), on top of
    /// the entry-count limit.
    nonisolated static let defaultCacheCostLimit = 128 * 1_024 * 1_024

    /// Default cap on the response body accepted for decode (10 MB), enforced
    /// on bytes delivered by the transport as the body streams in.
    nonisolated static let defaultMaxResponseBytes = 10 * 1_024 * 1_024

    /// Decodes image bytes with the longest pixel edge capped at `maxPixelEdge`
    /// (orientation-corrected), so a server-controlled avatar or icon URL can
    /// never materialize a full-resolution bitmap — a socially linked 4000×3000
    /// photo decodes as a bounded thumbnail instead of ~48 MB of bitmap for a
    /// 16–80 pt view. Small sources come back at their native size; ImageIO
    /// never upscales. When ImageIO cannot produce a thumbnail, the direct
    /// decode path accepts only a recognized bitmap container whose declared
    /// pixel dimensions already fit the cap; documents and other payloads
    /// `PlatformImage` could otherwise rasterize are rejected.
    nonisolated static func decodeBoundedImage(
        from data: Data,
        maxPixelEdge: CGFloat
    ) throws -> PlatformImage {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(
                  data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              isBitmapImageSource(source)
        else {
            throw URLError(.cannotDecodeContentData)
        }
        if let cgImage = makeThumbnail(from: source, maxPixelEdge: maxPixelEdge) {
            return platformImage(from: cgImage)
        }
        guard let image = boundedFallbackImage(
            from: data,
            source: source,
            maxPixelEdge: maxPixelEdge
        ) else {
            throw URLError(.cannotDecodeContentData)
        }
        return image
    }

    /// Whether ImageIO identifies `source` as a bitmap image container.
    ///
    /// The type gate runs before the thumbnail pass: ImageIO can thumbnail
    /// some non-image documents (PDF on macOS), and an avatar URL must never
    /// put a document in the image cache just because a thumbnail was
    /// available.
    private nonisolated static func isBitmapImageSource(_ source: CGImageSource) -> Bool {
        #if canImport(UniformTypeIdentifiers)
        guard let type = CGImageSourceGetType(source) else { return false }
        return UTType(type as String)?.conforms(to: .image) == true
        #else
        return CGImageSourceGetCount(source) > 0
        #endif
    }

    /// The direct-decode fallback used only when ImageIO cannot produce a
    /// thumbnail. It accepts a recognized bitmap container whose declared
    /// pixel dimensions already fit `maxPixelEdge`, so the decoded bitmap is
    /// bounded by the same cap. Non-image documents (PDF) and containers
    /// ImageIO does not identify as images (SVG) are refused instead of being
    /// rasterized through `PlatformImage(data:)`; oversized sources are
    /// refused rather than decoded at native size.
    nonisolated static func boundedFallbackImage(
        from data: Data,
        source: CGImageSource,
        maxPixelEdge: CGFloat
    ) -> PlatformImage? {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0,
              height > 0,
              CGFloat(max(width, height)) <= maxPixelEdge
        else {
            return nil
        }
        #if canImport(UniformTypeIdentifiers)
        guard let type = CGImageSourceGetType(source),
              UTType(type as String)?.conforms(to: .image) == true
        else {
            return nil
        }
        #endif
        return PlatformImage(data: data)
    }

    /// Approximate decoded byte size of `image`, used as the `NSCache` cost so
    /// the cache respects a byte budget instead of only an entry count.
    /// Returns `0` when the image has no bitmap representation;
    /// ``storableCacheCost(of:)`` is the gate the fetch path uses so such an
    /// entry can never bypass the budget.
    nonisolated static func cacheCost(of image: PlatformImage) -> Int {
        guard let cgImage = cgImage(of: image) else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }

    /// The cache cost for an image that is safe to store, or `nil` when it has
    /// no bitmap representation and would be charged zero against the byte
    /// budget.
    nonisolated static func storableCacheCost(of image: PlatformImage) -> Int? {
        let cost = cacheCost(of: image)
        return cost > 0 ? cost : nil
    }

    /// Pixel dimensions of `image`'s decoded bitmap; internal so tests can
    /// assert decode bounds without depending on platform point/scale rules.
    nonisolated static func decodedPixelDimensions(of image: PlatformImage) -> (width: Int, height: Int) {
        guard let cgImage = cgImage(of: image) else { return (0, 0) }
        return (cgImage.width, cgImage.height)
    }

    /// Mirrors `PhotoAttachmentHelper.downscaledImageData`: decode through
    /// ImageIO with a pixel-size cap instead of materializing the source at
    /// full resolution.
    private nonisolated static func makeThumbnail(from source: CGImageSource, maxPixelEdge: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelEdge,
            kCGImageSourceShouldCache: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private nonisolated static func platformImage(from cgImage: CGImage) -> PlatformImage {
        #if canImport(UIKit)
        UIImage(cgImage: cgImage)
        #elseif canImport(AppKit)
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }

    private nonisolated static func cgImage(of image: PlatformImage) -> CGImage? {
        #if canImport(UIKit)
        image.cgImage
        #elseif canImport(AppKit)
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }

    /// Returns the failure remembered for `url` while it is still inside the
    /// retry window, pruning the entry once its window has lapsed.
    private func recentFailure(for url: URL) -> FailedFetch? {
        guard let failure = recentFailures[url] else { return nil }
        if now().timeIntervalSince(failure.date) < failureRetryInterval {
            return failure
        }
        recentFailures.removeValue(forKey: url)
        return nil
    }

    /// Records a download failure for `url` and opportunistically prunes
    /// expired entries so the ledger stays bounded to one retry window.
    private func recordFailure(_ error: any Error, for url: URL) {
        let currentTime = now()
        recentFailures[url] = FailedFetch(date: currentTime, error: error)
        let cutoff = currentTime.addingTimeInterval(-failureRetryInterval)
        recentFailures = recentFailures.filter { $0.value.date > cutoff }
    }

    /// Finalizes a successful download from inside the detached background task,
    /// storing the decoded bitmap in cache and clearing the in-flight entry so
    /// cache warming succeeds even if the caller task was cancelled (issue #174).
    @MainActor
    private func recordCompletedImage(_ image: PlatformImage, cost: Int, for url: URL) {
        inFlight.removeValue(forKey: url)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
        recentFailures.removeValue(forKey: url)
    }

    /// Finalizes a failed download from inside the detached background task,
    /// cleaning up the in-flight entry and recording genuine failures in the
    /// negative cache while ignoring task cancellations.
    @MainActor
    private func recordCompletedFailure(_ error: any Error, for url: URL) {
        inFlight.removeValue(forKey: url)
        if !error.isSdkCancellation {
            recordFailure(error, for: url)
        }
    }

    /// Thread-safe coordinator for awaiting a background task with caller
    /// cancellation support, allowing the caller to disconnect immediately on
    /// cancellation while the background task runs to completion (issue #174).
    private final class TaskJoinState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<PlatformImage, Error>?
        private var result: Result<PlatformImage, Error>?

        func setContinuation(_ continuation: CheckedContinuation<PlatformImage, Error>) {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func resume(returning value: PlatformImage) {
            lock.lock()
            guard result == nil else {
                lock.unlock()
                return
            }
            result = .success(value)
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(returning: value)
        }

        func resume(throwing error: any Error) {
            lock.lock()
            guard result == nil else {
                lock.unlock()
                return
            }
            result = .failure(error)
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(throwing: error)
        }
    }

    /// Awaits `task` while propagating caller cancellation immediately, so a
    /// cancelled caller (e.g. view dismissal or scroll-away) disconnects with
    /// `CancellationError` without waiting for the slow download, while the
    /// detached background task continues running to warm the cache (issue #174).
    private func awaitJoinedTask(_ task: Task<PlatformImage, Error>) async throws -> PlatformImage {
        try Task.checkCancellation()
        let state = TaskJoinState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.setContinuation(continuation)
                Task {
                    do {
                        let image = try await task.value
                        state.resume(returning: image)
                    } catch {
                        state.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            state.resume(throwing: CancellationError())
        }
    }
}
