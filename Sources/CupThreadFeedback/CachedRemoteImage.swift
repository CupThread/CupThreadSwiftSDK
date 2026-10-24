import SwiftUI

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

    /// Whether a failed load attempt maps to `failure`. Task cancellation
    /// does not: a scrolled-away or recycled cell keeps its current phase —
    /// the detached download keeps running and may still land in the cache,
    /// resolving the next appearance — instead of flashing the failure
    /// placeholder for an error the user can never see (issue #421).
    static func mapsToFailurePhase(_ error: any Error) -> Bool {
        !(error.isSdkCancellation || Task.isCancelled)
    }
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
/// schemes collapse immediately to `.failure` without downloading, and the
/// loader never follows a redirect off the URL's HTTPS origin, so the
/// HTTPS-only guarantee covers the whole transfer rather than the first hop.
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
                    guard RemoteImagePhase.mapsToFailurePhase(error) else { return }
                    phase = .failure
                }
            }
    }
}
