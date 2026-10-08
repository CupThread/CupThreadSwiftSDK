import SwiftUI
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
    private var inFlight: [URL: Task<PlatformImage, Error>] = [:]
    private var recentFailures: [URL: FailedFetch] = [:]

    /// - Parameters:
    ///   - session: Session used for downloads; inject a test session to
    ///     intercept requests.
    ///   - cacheCountLimit: Maximum number of decoded images retained.
    ///   - failureRetryInterval: How long a failed fetch is remembered before
    ///     the URL becomes eligible for a new download attempt.
    ///   - now: Clock used for the negative-cache window; inject for tests.
    init(
        session: URLSession = .shared,
        cacheCountLimit: Int = 500,
        failureRetryInterval: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.failureRetryInterval = failureRetryInterval
        self.now = now
        cache.countLimit = cacheCountLimit
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
        let task: Task<PlatformImage, Error> = Task.detached { [session] in
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            guard let image = PlatformImage(data: data) else {
                throw URLError(.cannotDecodeContentData)
            }
            return image
        }
        inFlight[url] = task

        defer { inFlight.removeValue(forKey: url) }
        do {
            let image = try await task.value
            cache.setObject(image, forKey: url as NSURL)
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
