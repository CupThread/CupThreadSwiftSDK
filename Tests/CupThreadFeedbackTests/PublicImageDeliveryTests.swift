import Foundation
import ImageIO
import Testing
@testable import CupThreadFeedback

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Public Image Delivery & Thumbnail Size Hints Tests (Issue #354)

@Suite("PublicImageDelivery", .serialized)
struct PublicImageDeliveryTests {
    // Valid 16x16 WebP image fixture base64
    private static let webpFixtureBase64 = "UklGRjoAAABXRUJQVlA4IC4AAACQAQCdASoQABAAAUAmJaACdLoAA5gA/vtV4/+lwf/S4P/pcH/pcH8bss4bpAAA"

    private func makeWebPData() -> Data {
        Data(base64Encoded: Self.webpFixtureBase64)!
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []

        func record(_ url: URL) {
            lock.lock()
            urls.append(url)
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return urls.count
        }

        func contains(_ url: URL) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return urls.contains(url)
        }
    }

    // MARK: - Documented Enum Values & Aliases

    @Test func documentedThumbnailWidthEnumValuesAndAliases() {
        let expectedRawValues = [16, 32, 36, 56, 64, 72, 80, 112, 128, 160]
        let actualRawValues = PublicImageThumbnailWidth.allCases.map(\.rawValue)
        #expect(actualRawValues == expectedRawValues)

        #expect(PublicImageThumbnailWidth.allowedWidths == Set(expectedRawValues))

        // Verify shorthand aliases
        #expect(PublicImageThumbnailWidth.w16 == .width16)
        #expect(PublicImageThumbnailWidth.w32 == .width32)
        #expect(PublicImageThumbnailWidth.w36 == .width36)
        #expect(PublicImageThumbnailWidth.w56 == .width56)
        #expect(PublicImageThumbnailWidth.w64 == .width64)
        #expect(PublicImageThumbnailWidth.w72 == .width72)
        #expect(PublicImageThumbnailWidth.w80 == .width80)
        #expect(PublicImageThumbnailWidth.w112 == .width112)
        #expect(PublicImageThumbnailWidth.w128 == .width128)
        #expect(PublicImageThumbnailWidth.w160 == .width160)

        // Verify invalid / unsupported widths fail to initialize
        let unsupportedValues = [-16, 0, 10, 15, 20, 24, 48, 50, 100, 200, 256, 512]
        for val in unsupportedValues {
            #expect(PublicImageThumbnailWidth(rawValue: val) == nil, "Expected \(val) to be rejected as unsupported")
        }
    }

    // MARK: - Thumbnail URL Construction & Query Preservation

    @Test func thumbnailURLAppendsDocumentedWidthParameter() throws {
        let original = URL(string: "https://api.cupthread.com/api/v1/files/images%2Favatar.png")!
        let thumb32 = publicImageThumbnailURL(for: original, width: .width32)
        #expect(thumb32.absoluteString == "https://api.cupthread.com/api/v1/files/images%2Favatar.png?width=32")

        let thumb80 = publicImageThumbnailURL(for: original, width: .w80)
        #expect(thumb80.absoluteString == "https://api.cupthread.com/api/v1/files/images%2Favatar.png?width=80")
    }

    @Test func thumbnailURLPreservesExistingQueryParameters() throws {
        let original = URL(string: "https://api.cupthread.com/api/v1/files/images%2Ficon.png?theme=dark&version=2")!
        let thumb64 = publicImageThumbnailURL(for: original, width: .width64)

        let components = try #require(URLComponents(url: thumb64, resolvingAgainstBaseURL: false))
        let items = try #require(components.queryItems)
        #expect(items.first(where: { $0.name == "theme" })?.value == "dark")
        #expect(items.first(where: { $0.name == "version" })?.value == "2")
        #expect(items.first(where: { $0.name == "width" })?.value == "64")
    }

    @Test func thumbnailURLReplacesExistingWidthWithoutDuplication() throws {
        let original = URL(string: "https://api.cupthread.com/api/v1/files/images%2Ficon.png?width=16&tag=brand")!
        let thumb128 = publicImageThumbnailURL(for: original, width: .width128)

        let components = try #require(URLComponents(url: thumb128, resolvingAgainstBaseURL: false))
        let items = try #require(components.queryItems)
        let widthItems = items.filter { $0.name == "width" }
        #expect(widthItems.count == 1)
        #expect(widthItems.first?.value == "128")
        #expect(items.first(where: { $0.name == "tag" })?.value == "brand")
    }

    @Test func thumbnailURLPreservesPercentEncodedPathAsOpaqueURL() throws {
        let original = URL(string: "https://api.cupthread.com/api/v1/files/images%2Fsubfolder%2Favatar%201.png")!
        let thumb = publicImageThumbnailURL(for: original, width: .width56)

        let components = try #require(URLComponents(url: thumb, resolvingAgainstBaseURL: false))
        #expect(components.percentEncodedPath == "/api/v1/files/images%2Fsubfolder%2Favatar%201.png")
        #expect(components.queryItems?.first(where: { $0.name == "width" })?.value == "56")
    }

    // MARK: - Original-image Fallback

    @Test func thumbnailURLOriginalImageFallbackForNilAndUnsupportedWidths() {
        let original = URL(string: "https://api.cupthread.com/api/v1/files/images%2Favatar.png")!

        // Nil width falls back to original URL
        let nilWidth = publicImageThumbnailURL(for: original, width: nil as PublicImageThumbnailWidth?)
        #expect(nilWidth == original)

        // Integer nil falls back to original URL
        let nilIntWidth = publicImageThumbnailURL(for: original, width: nil as Int?)
        #expect(nilIntWidth == original)

        // Unsupported integers fall back to original URL
        #expect(publicImageThumbnailURL(for: original, width: 42) == original)
        #expect(publicImageThumbnailURL(for: original, width: 250) == original)
        #expect(publicImageThumbnailURL(for: original, width: 0) == original)
        #expect(publicImageThumbnailURL(for: original, width: -1) == original)

        // Supported integer resolves
        #expect(publicImageThumbnailURL(for: original, width: 64).absoluteString ==
            "https://api.cupthread.com/api/v1/files/images%2Favatar.png?width=64")

        // URL extension helpers
        #expect(original.appendingThumbnailWidth(nil as PublicImageThumbnailWidth?) == original)
        #expect(original.appendingThumbnailWidth(nil as Int?) == original)
        #expect(original.appendingThumbnailWidth(50) == original)
        #expect(original.appendingThumbnailWidth(112).absoluteString ==
            "https://api.cupthread.com/api/v1/files/images%2Favatar.png?width=112")
        #expect(original.appendingThumbnailWidth(.w160).absoluteString ==
            "https://api.cupthread.com/api/v1/files/images%2Favatar.png?width=160")
    }

    @Test func stringBasedThumbnailURLHelperValidatesPolicyAndFallsBack() {
        #expect(publicImageThumbnailURL(from: nil, width: .width32) == nil)
        #expect(publicImageThumbnailURL(from: "", width: .width32) == nil)
        #expect(publicImageThumbnailURL(from: "   ", width: .width32) == nil)
        #expect(publicImageThumbnailURL(from: "http://insecure.com/a.png", width: .width32) == nil)
        #expect(publicImageThumbnailURL(from: "file:///local/a.png", width: .width32) == nil)

        let validStr = "https://api.cupthread.com/api/v1/files/images%2Favatar.png"
        let expectedOriginal = URL(string: validStr)!

        // Without width returns original valid URL
        #expect(publicImageThumbnailURL(from: validStr, width: nil as PublicImageThumbnailWidth?) == expectedOriginal)

        // With supported width returns thumb URL
        #expect(publicImageThumbnailURL(from: validStr, width: .width16) ==
            URL(string: "https://api.cupthread.com/api/v1/files/images%2Favatar.png?width=16"))

        // With unsupported int width falls back to original URL
        #expect(publicImageThumbnailURL(from: validStr, width: 99) == expectedOriginal)

        // With supported int width returns thumb URL
        #expect(publicImageThumbnailURL(from: validStr, width: 72) ==
            URL(string: "https://api.cupthread.com/api/v1/files/images%2Favatar.png?width=72"))
    }

    // MARK: - AvatarView Integration

    @MainActor
    @Test func avatarViewSupportsOptionalThumbnailWidth() {
        let validStr = "https://api.cupthread.com/api/v1/files/images%2Favatar.png"

        // Default has no width hint
        let defaultAvatar = AvatarView(url: validStr)
        #expect(defaultAvatar.resolvedURL == URL(string: validStr))

        // Specified thumbnail width attaches width hint
        let thumbAvatar = AvatarView(url: validStr, size: 32, thumbnailWidth: .width64)
        #expect(thumbAvatar.resolvedURL == URL(string: "https://api.cupthread.com/api/v1/files/images%2Favatar.png?width=64"))

        // Insecure URL remains nil even with thumbnail width specified
        let insecureAvatar = AvatarView(url: "http://insecure.example.com/avatar.png", thumbnailWidth: .width32)
        #expect(insecureAvatar.resolvedURL == nil)
    }

    // MARK: - RemoteImageLoader WebP & Independent Cache Partitioning

    @MainActor
    @Test func remoteImageLoaderDecodesWebPThumbnailRegardlessOfURLExtension() async throws {
        let host = "webp-test-\(UUID().uuidString).cupthread.com"
        let webpData = makeWebPData()
        let fakePngURL = URL(string: "https://\(host)/api/v1/files/images%2Fuser.png?width=32")!

        MockURLProtocol.setHandler(forHost: host) { request in
            let response = HTTPURLResponse(
                url: request.url ?? fakePngURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "image/webp",
                    "Cache-Control": "public, max-age=300"
                ]
            )!
            return (response, webpData)
        }
        defer { MockURLProtocol.setHandler(forHost: host, nil) }

        let loader = RemoteImageLoader(session: makeMockSession())
        let loaded = try await loader.image(for: fakePngURL)

        let dims = RemoteImageLoader.decodedPixelDimensions(of: loaded)
        #expect(dims.width == 16)
        #expect(dims.height == 16)
    }

    @MainActor
    @Test func remoteImageLoaderCachesDistinctWidthHintsIndependently() async throws {
        let host = "cache-test-\(UUID().uuidString).cupthread.com"
        let recorder = RequestRecorder()
        let webpData = makeWebPData()

        MockURLProtocol.setHandler(forHost: host) { request in
            if let url = request.url {
                recorder.record(url)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/webp", "Cache-Control": "public, max-age=300"]
            )!
            return (response, webpData)
        }
        defer { MockURLProtocol.setHandler(forHost: host, nil) }

        let originalURL = URL(string: "https://\(host)/api/v1/files/images%2Ficon.png")!
        let thumb32URL = publicImageThumbnailURL(for: originalURL, width: .width32)
        let thumb64URL = publicImageThumbnailURL(for: originalURL, width: .width64)

        let loader = RemoteImageLoader(session: makeMockSession())

        // Fetch both variants
        let image32 = try await loader.image(for: thumb32URL)
        let image64 = try await loader.image(for: thumb64URL)

        #expect(recorder.count == 2)
        #expect(recorder.contains(thumb32URL))
        #expect(recorder.contains(thumb64URL))

        // Subsequent fetches for each URL resolve from cache without hitting network again
        let cached32 = try await loader.image(for: thumb32URL)
        let cached64 = try await loader.image(for: thumb64URL)

        #expect(recorder.count == 2) // Network was not called again
        #expect(cached32 === image32)
        #expect(cached64 === image64)
    }
}
