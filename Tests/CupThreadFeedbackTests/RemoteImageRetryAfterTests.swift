import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import CupThreadFeedback

@Suite("RemoteImageRetryAfter", .serialized)
@MainActor
struct RemoteImageRetryAfterTests {
    private static let host = "image-retry.example.com"
    private static let imageURL = URL(
        string: "https://\(host)/api/v1/files/images%2Favatar.png"
    )!

    private final class SteppingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSinceReferenceDate: 0)

        var now: Date {
            lock.lock()
            defer { lock.unlock() }
            return current
        }

        func advance(by interval: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            current = current.addingTimeInterval(interval)
        }
    }

    private final class ImageResponseScript: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0
        private let unavailableData: Data
        private let imageData: Data
        private let fallbackURL: URL

        init(fallbackURL: URL, unavailableData: Data, imageData: Data) {
            self.fallbackURL = fallbackURL
            self.unavailableData = unavailableData
            self.imageData = imageData
        }

        func next(for request: URLRequest) throws -> (URLResponse, Data) {
            lock.lock()
            defer { lock.unlock() }
            attempts += 1
            let response = makeHTTPResponse(
                status: attempts == 1 ? 503 : 200,
                url: request.url ?? fallbackURL,
                headers: attempts == 1 ? [
                    "Cache-Control": "no-store",
                    "Content-Type": "application/json",
                    "Retry-After": "20"
                ] : ["Content-Type": "image/png"]
            )
            return (response, attempts == 1 ? unavailableData : imageData)
        }

        var attemptCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return attempts
        }
    }

    @Test func serviceUnavailableUsesRetryAfterBeforeGenericWindow() async throws {
        let clock = SteppingClock()
        let png = try Self.makePNGData()
        let responses = ImageResponseScript(
            fallbackURL: Self.imageURL,
            unavailableData: try encodeJSON(["code": "resource_protection"]),
            imageData: png
        )
        let loader = RemoteImageLoader(
            session: makeMockSession(),
            failureRetryInterval: 5,
            now: { clock.now }
        )

        MockURLProtocol.setHandler(forHost: Self.host) { request in
            try responses.next(for: request)
        }
        defer { MockURLProtocol.setHandler(forHost: Self.host, nil) }

        await #expect(throws: RemoteImageServiceUnavailable(retryAfter: 20)) {
            try await loader.image(for: Self.imageURL)
        }
        #expect(loader.cachedImageIfPresent(for: Self.imageURL) == nil)
        #expect(responses.attemptCount == 1)

        clock.advance(by: 5)
        await #expect(throws: RemoteImageServiceUnavailable(retryAfter: 20)) {
            try await loader.image(for: Self.imageURL)
        }
        #expect(responses.attemptCount == 1, "Retry-After must override the shorter generic window")

        clock.advance(by: 15)
        let image = try await loader.image(for: Self.imageURL)
        #expect(responses.attemptCount == 2, "A lapsed Retry-After must allow recovery")
        #expect(loader.cachedImageIfPresent(for: Self.imageURL) != nil)

        let cachedImage = try await loader.image(for: Self.imageURL)
        #expect(cachedImage == image)
        #expect(responses.attemptCount == 2, "A recovered image must be decoded-cache hit")
    }

    @Test func retryAfterParserAcceptsOnlyFiniteNonNegativeValues() {
        let response = makeHTTPResponse(status: 503, headers: ["Retry-After": "30"])
        #expect(RetryAfterParser.interval(from: response) == 30)

        let invalidValues = ["-1", "nan", "inf", "tomorrow"]
        for value in invalidValues {
            let invalid = makeHTTPResponse(status: 503, headers: ["Retry-After": value])
            #expect(RetryAfterParser.interval(from: invalid) == nil)
        }
    }

    private static func makePNGData() throws -> Data {
        let context = try #require(CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
