import Foundation
import ImageIO
import os
import Testing
@testable import CupThreadFeedback

/// Behavioral guards for the executor the photo preparation pipeline runs on
/// and for the error mapping of undecodable bytes (#79).
@Suite("PhotoPreparationThreading")
struct PhotoPreparationThreadingTests {

    // MARK: - Off-main-actor execution (#79)

    /// Lock-protected boolean shared between the test task and the observer
    /// task; each access takes the lock for a single store/load, never across
    /// an await.
    private final class SharedFlag: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: false)

        var value: Bool {
            get { state.withLock { $0 } }
            set { state.withLock { $0 = newValue } }
        }
    }

    @MainActor
    @Test func prepareForUploadRunsOffTheMainActor() async throws {
        // Build the worst-case fixture on the cooperative pool first: the
        // noise fill and encode are seconds of CPU work, and generating it
        // inside this @MainActor body would stall every other MainActor
        // test in the suite — the very freeze this test exists to prevent.
        let slow = try await Self.makeSlowFixture()

        let finished = SharedFlag()
        let mainActorTickedDuringPreparation = SharedFlag()

        // The observer is enqueued on the MainActor before the preparation
        // call; the test task holds the actor until it suspends, so the
        // observer can only start once `await` below suspends.
        let observer = Task { @MainActor in
            // Tick every 20 ms until preparation finishes. If the pipeline
            // ever runs on the MainActor again, this loop cannot make
            // progress while the CPU-bound work executes, and no tick will
            // have been recorded by the time `finished` flips.
            while !finished.value {
                mainActorTickedDuringPreparation.value = true
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        // Called from the MainActor test task: the preparation must hop to
        // the global concurrent executor and leave the MainActor free to run
        // the observer's ticks while the CPU work is still in flight.
        let prepared: PhotoAttachmentHelper.PreparedPhoto
        do {
            prepared = try await PhotoAttachmentHelper.prepareForUpload(
                slow,
                limit: 20_000_000,
                stripSensitiveMetadata: true
            )
        } catch {
            finished.value = true
            await observer.value
            throw error
        }
        finished.value = true

        await observer.value

        #expect(mainActorTickedDuringPreparation.value)
        #expect(prepared.mimeType == "image/jpeg")
    }

    // MARK: - Error mapping for undecodable bytes (#79)

    @Test func prepareForUploadPreservesErrorMappingForUndecodableBytes() async throws {
        let garbage = Data("definitely not an image".utf8)

        do {
            _ = try await PhotoAttachmentHelper.prepareForUpload(garbage, limit: 20_000_000, stripSensitiveMetadata: true)
            Issue.record("Expected unprocessableImage for undecodable bytes with stripping enabled")
        } catch let error as AttachmentValidationError {
            #expect(error == .unprocessableImage)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        do {
            _ = try await PhotoAttachmentHelper.prepareForUpload(garbage, limit: 20_000_000, stripSensitiveMetadata: false)
            Issue.record("Expected unsupportedType for undecodable bytes with stripping disabled")
        } catch let error as AttachmentValidationError {
            #expect(error == .unsupportedType)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - Test Fixture Helpers

    private struct FixtureUnavailableError: Error {}

    /// Builds the worst-case JPEG fixture off the MainActor. Random-pixel
    /// noise is the JPEG codec's heaviest input, keeping the pipeline's
    /// decode + strip re-encode reliably well above the observer's tick
    /// interval without turning the fixture into a CI time sink.
    nonisolated private static func makeSlowFixture() async throws -> Data {
        guard let image = createTestImage(width: 2_048, height: 2_048, noise: true),
              let fixture = createJPEGFixture(
                  cgImage: image,
                  quality: 0.8,
                  gps: [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLongitude: -122.03]
              ) else {
            throw FixtureUnavailableError()
        }
        return fixture
    }

    private static func createTestImage(width: Int, height: Int, noise: Bool = false) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }
        if noise {
            guard let buffer = context.data else { return nil }
            let pixels = buffer.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
            for row in 0..<height {
                let rowStart = row * context.bytesPerRow
                for column in 0..<(width * 4) {
                    pixels[rowStart + column] = UInt8.random(in: 0...255)
                }
            }
        } else {
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1.0))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return context.makeImage()
    }

    private static func createJPEGFixture(
        cgImage: CGImage,
        quality: CGFloat = 0.9,
        gps: [CFString: Any]? = nil
    ) -> Data? {
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        if let gps {
            properties[kCGImagePropertyGPSDictionary] = gps
        }
        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }
}
