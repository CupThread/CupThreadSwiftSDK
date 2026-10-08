import SwiftUI
import ImageIO
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
/// render at 16–80 pt, so full-resolution sources are pure waste), oversized
/// response bodies are rejected before decode, and the cache enforces a byte
/// budget charged with each decoded bitmap's size in addition to its entry
/// count.
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
    private let cache = NSCache<NSURL, PlatformImage>()
    private let failureRetryInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let maxDecodedPixelEdge: CGFloat
    private let maxResponseBytes: Int
    private var inFlight: [URL: Task<PlatformImage, Error>] = [:]
    private var recentFailures: [URL: FailedFetch] = [:]

    /// - Parameters:
    ///   - session: Session used for downloads; inject a test session to
    ///     intercept requests.
    ///   - cacheCountLimit: Maximum number of decoded images retained.
    ///   - cacheCostLimit: Byte budget for the decoded bitmaps retained in
    ///     the cache; each entry is charged its decoded bitmap size, so the
    ///     budget is deterministic once decode is pixel-bounded.
    ///   - maxDecodedPixelEdge: Cap for the decoded bitmap's longest pixel
    ///     edge; comfortably above the largest consumer (80 pt @3x = 240 px)
    ///     with headroom for future surfaces. Small sources are never
    ///     upscaled.
    ///   - maxResponseBytes: Maximum encoded response body accepted for
    ///     decode; larger bodies throw `URLError(.cannotDecodeContentData)`
    ///     without being cached.
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
        self.session = session
        self.failureRetryInterval = failureRetryInterval
        self.now = now
        cache.countLimit = cacheCountLimit
        cache.totalCostLimit = cacheCostLimit
        self.maxDecodedPixelEdge = maxDecodedPixelEdge
        self.maxResponseBytes = maxResponseBytes
    }

    /// Returns the decoded image for `url`, downloading it at most once per
    /// cache lifetime. Concurrent callers for the same URL share one download.
    ///
    /// URLs are validated against `isAllowedSecureImageURL(_:)`; non-HTTPS or disallowed schemes
    /// (`http:`, `file:`, `data:`, `javascript:`, etc.) immediately throw `URLError(.badURL)`
    /// without contacting the network or consulting the cache.
    ///
/// A download that fails is remembered for `failureRetryInterval`; calls
/// inside that window rethrow the recorded error without a network request.
///
/// Memory is bounded end to end: the decoded bitmap's longest pixel edge is
/// capped at `maxDecodedPixelEdge` via an ImageIO thumbnail decode (avatars
/// and icons render at 16–80 pt), responses larger than `maxResponseBytes`
/// are rejected before decode, and the cache carries a byte budget
/// (`cacheCostLimit`, charged with each image's decoded bitmap size) on top
/// of the entry-count limit — so a server-controlled oversized avatar can
/// neither spike decode memory nor accumulate unbounded retained bitmaps.
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
            return try await existing.value
        }

        // Detached so decode happens off the MainActor. Deliberately not
        // cancelled when a subscriber goes away: the image lands in the cache
        // either way, so the next appearance resolves instantly.
        let task: Task<PlatformImage, Error> = Task.detached { [session, maxResponseBytes, maxDecodedPixelEdge] in
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            // A server mistake must not turn an avatar fetch into a memory
            // spike even before the pixel bound applies; the failure replays
            // through the negative cache like any other.
            guard data.count <= maxResponseBytes else {
                throw URLError(.cannotDecodeContentData)
            }
            return try Self.decodeBoundedImage(from: data, maxPixelEdge: maxDecodedPixelEdge)
        }
        inFlight[url] = task

        defer { inFlight.removeValue(forKey: url) }
        do {
            let image = try await task.value
            cache.setObject(image, forKey: url as NSURL, cost: Self.cacheCost(of: image))
            recentFailures.removeValue(forKey: url)
            return image
        } catch {
            recordFailure(error, for: url)
            throw error
        }
    }

    /// Number of URLs currently remembered as recently failed; internal so
    /// tests can assert the ledger stays bounded.
    var recentFailureCount: Int { recentFailures.count }

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

    /// Default cap on the encoded response body accepted for decode (10 MB).
    nonisolated static let defaultMaxResponseBytes = 10 * 1_024 * 1_024

    /// Decodes image bytes with the longest pixel edge capped at `maxPixelEdge`
    /// (orientation-corrected), so a server-controlled avatar or icon URL can
    /// never materialize a full-resolution bitmap — a socially linked 4000×3000
    /// photo decodes as a bounded thumbnail instead of ~48 MB of bitmap for a
    /// 16–80 pt view. Small sources come back at their native size; ImageIO
    /// never upscales. Falls back to a direct `PlatformImage(data:)` decode
    /// when ImageIO cannot produce a thumbnail.
    nonisolated static func decodeBoundedImage(
        from data: Data,
        maxPixelEdge: CGFloat
    ) throws -> PlatformImage {
        if let cgImage = makeThumbnail(from: data, maxPixelEdge: maxPixelEdge) {
            return platformImage(from: cgImage)
        }
        guard let image = PlatformImage(data: data) else {
            throw URLError(.cannotDecodeContentData)
        }
        return image
    }

    /// Approximate decoded byte size of `image`, used as the `NSCache` cost so
    /// the cache respects a byte budget instead of only an entry count.
    nonisolated static func cacheCost(of image: PlatformImage) -> Int {
        guard let cgImage = cgImage(of: image) else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
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
    private nonisolated static func makeThumbnail(from data: Data, maxPixelEdge: CGFloat) -> CGImage? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else {
            return nil
        }
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
}

// MARK: - Phase

/// AsyncImage-like phase for `CachedRemoteImage`. Failure collapses to a bare
/// case because callers render the same placeholder while loading and on error.
enum RemoteImagePhase {
    /// Nothing loaded yet.
    case empty
    /// The image, ready to render.
    case success(Image)
    /// The download or decode failed; the loader remembers the failure for a
    /// short negative-cache window (replaying it without a network request)
    /// and retries the download on the next appearance after it lapses.
    case failure
}

// MARK: - View

extension Image {
    #if canImport(UIKit)
    init(platformImage image: UIImage) {
        self = Image(uiImage: image)
    }
    #elseif canImport(AppKit)
    init(platformImage image: NSImage) {
        self = Image(nsImage: image)
    }
    #endif
}

/// Drop-in replacement for `AsyncImage` backed by `RemoteImageLoader`: same
/// phase contract, but repeat appearances resolve from cache instantly and
/// concurrent subscribers for one URL share a single download. Disallowed URL
/// schemes collapse immediately to `.failure` without downloading.
struct CachedRemoteImage<Content: View>: View {
    let url: URL
    @ViewBuilder let content: (RemoteImagePhase) -> Content

    @State private var phase: RemoteImagePhase = .empty

    var body: some View {
        content(phase)
            .task(id: url) {
                guard isAllowedSecureImageURL(url) else {
                    phase = .failure
                    return
                }
                do {
                    phase = .success(
                        Image(platformImage: try await RemoteImageLoader.shared.image(for: url))
                    )
                } catch {
                    phase = .failure
                }
            }
    }
}
