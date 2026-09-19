import Foundation
import ImageIO
import Testing
@testable import CupThreadFeedback

@Suite("PhotoAttachmentPreparation")
struct PhotoAttachmentPreparationTests {

    // MARK: - downscaledImageData (#52)

    @Test func downscaledImageDataFitsHugePanoramaUnderLimit() throws {
        // 12000×3000 panorama-like source exceeds the default 4096 px cap.
        let image = try #require(createTestImage(width: 12_000, height: 3_000))
        let oversized = try #require(createJPEGFixture(cgImage: image))

        let downscaled = try #require(PhotoAttachmentHelper.downscaledImageData(oversized, limit: 5_000_000))

        #expect(downscaled.count <= 5_000_000)
        let dimensions = try #require(decodedDimensions(of: downscaled))
        #expect(dimensions.width <= 4096)
        #expect(dimensions.height <= 4096)
        #expect(dimensions.width < 12_000)
        let sniffed = PhotoAttachmentHelper.sniffImageFormat(from: downscaled)
        #expect(sniffed?.mimeType == "image/jpeg")
        #expect(sniffed?.fileExtension == "jpg")
    }

    @Test func downscaledImageDataHonorsCustomMaxDimension() throws {
        let image = try #require(createTestImage(width: 12_000, height: 3_000))
        let oversized = try #require(createJPEGFixture(cgImage: image))

        let downscaled = try #require(PhotoAttachmentHelper.downscaledImageData(oversized, limit: 5_000_000, maxDimension: 500))

        let dimensions = try #require(decodedDimensions(of: downscaled))
        #expect(dimensions.width <= 500)
        #expect(dimensions.height <= 500)
    }

    @Test func downscaledImageDataDropsGPSAndEXIFMetadata() throws {
        let image = try #require(createTestImage(width: 600, height: 400))
        let withMetadata = try #require(createJPEGFixture(
            cgImage: image,
            gps: [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLongitude: -122.03],
            exif: [kCGImagePropertyExifDateTimeOriginal: "2026:09:12 12:00:00"]
        ))

        let downscaled = try #require(PhotoAttachmentHelper.downscaledImageData(withMetadata, limit: 5_000_000))

        let properties = try #require(imageProperties(of: downscaled))
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] == nil)
    }

    @Test func downscaledImageDataReturnsNilForUndecodableBytes() {
        let garbage = Data(repeating: 0x42, count: 2_000_000)
        #expect(PhotoAttachmentHelper.downscaledImageData(garbage, limit: 1_000_000) == nil)
    }

    @Test func downscaledImageDataReturnsNilWhenLowestQualityStillExceedsLimit() throws {
        let image = try #require(createTestImage(width: 800, height: 600))
        let decodable = try #require(createJPEGFixture(cgImage: image))

        // No JPEG encode of a real 800×600 bitmap fits in 200 bytes.
        #expect(PhotoAttachmentHelper.downscaledImageData(decodable, limit: 200) == nil)
    }

    @Test func downscaledImageDataReturnsNilForEmptyData() {
        #expect(PhotoAttachmentHelper.downscaledImageData(Data(), limit: 1_000_000) == nil)
    }

    // MARK: - prepareForUpload pipeline (#52)

    @Test func prepareForUploadDownscalesOversizedPhotoToFitLimit() async throws {
        // Random-pixel noise stays above the limit until the quality floor,
        // exercising the full downscale/step path deterministically.
        let image = try #require(createTestImage(width: 2_000, height: 1_200, noise: true))
        let oversized = try #require(createJPEGFixture(cgImage: image, quality: 0.8))
        #expect(oversized.count > 1_500_000)

        let prepared = try await PhotoAttachmentHelper.prepareForUpload(oversized, limit: 1_500_000, stripSensitiveMetadata: false)

        #expect(prepared.data.count <= 1_500_000)
        #expect(prepared.mimeType == "image/jpeg")
        #expect(prepared.fileExtension == "jpg")
    }

    @Test func prepareForUploadPassesUnderLimitBytesThroughByteIdentical() async throws {
        let image = try #require(createTestImage(width: 50, height: 30))
        let png = try #require(createPNGFixture(cgImage: image))

        let prepared = try await PhotoAttachmentHelper.prepareForUpload(png, limit: 20_000_000, stripSensitiveMetadata: false)

        #expect(prepared.data == png)
        #expect(prepared.mimeType == "image/png")
        #expect(prepared.fileExtension == "png")
    }

    @Test func prepareForUploadSurfacesOversizedForUndecodableOversizedBytes() async throws {
        let garbage = Data(repeating: 0x42, count: 2_000_000)

        do {
            _ = try await PhotoAttachmentHelper.prepareForUpload(garbage, limit: 1_000_000, stripSensitiveMetadata: false)
            Issue.record("Expected oversized failure for undecodable oversized bytes")
        } catch let error as AttachmentValidationError {
            #expect(error == .oversized(size: garbage.count, limit: 1_000_000))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func prepareForUploadSurfacesOversizedWhenDownscaleCannotFitLimit() async throws {
        let image = try #require(createTestImage(width: 800, height: 600))
        let decodable = try #require(createJPEGFixture(cgImage: image))

        do {
            _ = try await PhotoAttachmentHelper.prepareForUpload(decodable, limit: 200, stripSensitiveMetadata: false)
            Issue.record("Expected oversized failure when no quality fits the limit")
        } catch let error as AttachmentValidationError {
            #expect(error == .oversized(size: decodable.count, limit: 200))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func prepareForUploadRejectsSVGBeforeSizeHandling() async {
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)

        do {
            _ = try await PhotoAttachmentHelper.prepareForUpload(svg, limit: 20_000_000, stripSensitiveMetadata: false)
            Issue.record("Expected unsupportedType for SVG markup")
        } catch let error as AttachmentValidationError {
            #expect(error == .unsupportedType)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func prepareForUploadAppliesMetadataStrippingWhenConfigured() async throws {
        let image = try #require(createTestImage(width: 600, height: 400))
        let withGPS = try #require(createJPEGFixture(
            cgImage: image,
            gps: [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLongitude: -122.03]
        ))

        let prepared = try await PhotoAttachmentHelper.prepareForUpload(withGPS, limit: 20_000_000, stripSensitiveMetadata: true)

        let properties = try #require(imageProperties(of: prepared.data))
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(prepared.mimeType == "image/jpeg")
    }

    @Test func prepareForUploadTranscodesUnderLimitHEICToJPEGIfSupported() async throws {
        // Skip quietly when the host cannot encode HEIC (older Linux-style CI images
        // or restricted encoders); the transcode path is covered by unit tests elsewhere.
        guard let image = createTestImage(width: 60, height: 40),
              let heic = createHEICFixture(cgImage: image) else {
            return
        }

        let prepared = try await PhotoAttachmentHelper.prepareForUpload(heic, limit: 20_000_000, stripSensitiveMetadata: false)

        #expect(prepared.mimeType == "image/jpeg")
        #expect(prepared.fileExtension == "jpg")
    }

    // MARK: - single re-encode pass (#79)

    @Test func prepareForUploadStripsHEICMetadataThroughTheSingleTranscodePass() async throws {
        // The JPEG transcode is itself a sanitizer, so a HEIC photo with
        // stripping enabled must come out as the single-transcode JPEG with
        // no GPS/EXIF, without paying a separate strip re-encode first (#79).
        guard let image = createTestImage(width: 60, height: 40),
              let heic = createHEICFixture(
                  cgImage: image,
                  gps: [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLongitude: -122.03]
              ) else {
            return
        }

        let prepared = try await PhotoAttachmentHelper.prepareForUpload(heic, limit: 20_000_000, stripSensitiveMetadata: true)

        #expect(prepared.data.starts(with: [0xFF, 0xD8, 0xFF]))
        let properties = try #require(imageProperties(of: prepared.data))
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(prepared.mimeType == "image/jpeg")
    }

    @Test func prepareForUploadDownscaleAloneSatisfiesStrippingForOversizedPhotos() async throws {
        // The downscale re-encode drops metadata by construction, so an
        // oversized photo must not run a second strip pass either (#79).
        let image = try #require(createTestImage(width: 2_000, height: 1_200, noise: true))
        let oversized = try #require(createJPEGFixture(
            cgImage: image,
            quality: 0.8,
            gps: [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLongitude: -122.03]
        ))

        let prepared = try await PhotoAttachmentHelper.prepareForUpload(oversized, limit: 1_500_000, stripSensitiveMetadata: true)

        #expect(prepared.data.count <= 1_500_000)
        let properties = try #require(imageProperties(of: prepared.data))
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(prepared.mimeType == "image/jpeg")
    }

    // MARK: - Test Fixture Helpers

    private func createTestImage(width: Int, height: Int, noise: Bool = false) -> CGImage? {
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

    private func createJPEGFixture(
        cgImage: CGImage,
        quality: CGFloat = 0.9,
        gps: [CFString: Any]? = nil,
        exif: [CFString: Any]? = nil
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
        if let exif {
            properties[kCGImagePropertyExifDictionary] = exif
        }
        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    private func createPNGFixture(cgImage: CGImage) -> Data? {
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            "public.png" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    private func createHEICFixture(cgImage: CGImage, gps: [CFString: Any]? = nil) -> Data? {
        let supportedTypes = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        guard supportedTypes.contains("public.heic") else { return nil }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            "public.heic" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        var properties: [CFString: Any] = [:]
        if let gps {
            properties[kCGImagePropertyGPSDictionary] = gps
        }
        CGImageDestinationAddImage(dest, cgImage, properties.isEmpty ? nil : properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    private func imageProperties(of data: Data) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        return properties
    }

    private func decodedDimensions(of data: Data) -> (width: Int, height: Int)? {
        guard let properties = imageProperties(of: data),
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }
}
