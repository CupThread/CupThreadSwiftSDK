import Foundation
import ImageIO
import Testing
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
@testable import CupThreadFeedback

// MARK: - Decode fallback and cache-cost bounds (PERF-7)

/// The direct `PlatformImage(data:)` fallback used to bypass both the pixel
/// cap and the cache's byte budget: on macOS it can rasterize PDF/SVG
/// documents at their declared size with a zero `cacheCost`. These tests pin
/// the fallback gates and the zero-cost cache rejection.
@Suite("RemoteImageLoader Decode Bounds")
struct RemoteImageLoaderDecodeBoundTests {
    private static let host = "image-decode-bound.test.example.com"

    @Test func fallbackRejectsContainersImageIODoesNotRecognize() {
        // ImageIO reports count 0 and no type for SVG, while NSImage on macOS
        // would rasterize it at the declared 100000×100000 size.
        let svg = Data(
            #"<svg xmlns="http://www.w3.org/2000/svg" width="100000" height="100000"></svg>"#.utf8
        )

        do {
            _ = try RemoteImageLoader.decodeBoundedImage(from: svg, maxPixelEdge: 600)
            Issue.record("Expected the unrecognized container to be rejected")
        } catch let error as URLError {
            #expect(error.code == .cannotDecodeContentData)
        } catch {
            Issue.record("Expected URLError, got \(error)")
        }
    }

    @Test func fallbackRejectsRecognizedBitmapsPastThePixelCap() throws {
        let png = try Self.makePNGData(width: 3_000, height: 3_000)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))

        #expect(
            RemoteImageLoader.boundedFallbackImage(from: png, source: source, maxPixelEdge: 600) == nil,
            "The direct fallback must not materialize a bitmap larger than the pixel cap"
        )
    }

    @Test func fallbackAcceptsRecognizedBitmapsWithinThePixelCap() throws {
        let png = try Self.makePNGData(width: 40, height: 30)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(
            RemoteImageLoader.boundedFallbackImage(from: png, source: source, maxPixelEdge: 600)
        )

        let dimensions = RemoteImageLoader.decodedPixelDimensions(of: image)
        #expect(dimensions.width == 40)
        #expect(dimensions.height == 30)
    }

    @Test func imageWithoutABitmapRepresentationHasNoStorableCost() {
        #expect(
            RemoteImageLoader.storableCacheCost(of: PlatformImage()) == nil,
            "An image with no bitmap backing would be charged zero against the byte budget"
        )
    }

    @Test func bitmapBackedImageHasAPositiveStorableCost() throws {
        let png = try Self.makePNGData(width: 4, height: 4)
        let image = try RemoteImageLoader.decodeBoundedImage(from: png, maxPixelEdge: 600)

        #expect(RemoteImageLoader.storableCacheCost(of: image) != nil)
    }

    @Test @MainActor func svgAvatarFailsThroughTheNegativeCache() async throws {
        let host = Self.host
        let url = URL(string: "https://\(host)/avatar.svg")!
        let svg = Data(
            #"<svg xmlns="http://www.w3.org/2000/svg" width="4096" height="4096"></svg>"#.utf8
        )
        MockURLProtocol.setHandler(forHost: host) { _ in
            (makeHTTPResponse(headers: ["Content-Type": "image/svg+xml"]), svg)
        }
        defer { MockURLProtocol.setHandler(forHost: host, nil) }

        let loader = RemoteImageLoader(session: makeMockSession())
        do {
            _ = try await loader.image(for: url)
            Issue.record("Expected the SVG payload to be rejected instead of rasterized")
        } catch let error as URLError {
            #expect(error.code == .cannotDecodeContentData)
        } catch {
            Issue.record("Expected URLError, got \(error)")
        }

        #expect(loader.cachedImageIfPresent(for: url) == nil)
        #expect(loader.recentFailureCount == 1)
    }

    private static func makePNGData(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
