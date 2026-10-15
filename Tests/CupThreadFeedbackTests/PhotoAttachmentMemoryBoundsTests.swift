import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import CupThreadFeedback

@Suite("PhotoAttachmentHelper Performance & Memory Bounds Tests")
struct PhotoAttachmentHelperMemoryBoundsTests {

    private func createTestCGImage(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        return context.makeImage()
    }

    private func createPNGData(cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            "public.png" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func createTIFFData(cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            "public.tiff" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func createHEICData(cgImage: CGImage) -> Data? {
        let supportedTypes = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        guard supportedTypes.contains("public.heic") else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            "public.heic" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func decodedDimensions(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }

    @Test("jpegRepresentationResampled constrains decoded pixel dimensions to custom maxDimension")
    func testJpegRepresentationResampledBoundsCustomMaxDimension() throws {
        let width = 5000
        let height = 3000
        let cgImage = try #require(createTestCGImage(width: width, height: height))
        let pngData = try #require(createPNGData(cgImage: cgImage))

        let resampled = try #require(
            PhotoAttachmentHelper.jpegRepresentationResampled(from: pngData, maxDimension: 2048)
        )
        let dimensions = try #require(decodedDimensions(of: resampled))

        #expect(max(dimensions.width, dimensions.height) <= 2048)
        #expect(dimensions.width > dimensions.height)
    }

    @Test("jpegRepresentationResampled defaults to 4096px maxDimension")
    func testJpegRepresentationResampledDefaultsTo4096() throws {
        let width = 5000
        let height = 3000
        let cgImage = try #require(createTestCGImage(width: width, height: height))
        let pngData = try #require(createPNGData(cgImage: cgImage))

        let resampled = try #require(
            PhotoAttachmentHelper.jpegRepresentationResampled(from: pngData)
        )
        let dimensions = try #require(decodedDimensions(of: resampled))

        #expect(max(dimensions.width, dimensions.height) <= 4096)
        #expect(dimensions.width > dimensions.height)
    }

    @Test("jpegRepresentationResampled preserves native dimensions when maxDimension is nil")
    func testJpegRepresentationResampledUnconstrainedWhenNil() throws {
        let width = 5000
        let height = 3000
        let cgImage = try #require(createTestCGImage(width: width, height: height))
        let pngData = try #require(createPNGData(cgImage: cgImage))

        let resampled = try #require(
            PhotoAttachmentHelper.jpegRepresentationResampled(from: pngData, maxDimension: nil)
        )
        let dimensions = try #require(decodedDimensions(of: resampled))

        #expect(dimensions.width == width)
        #expect(dimensions.height == height)
    }

    @Test("jpegRepresentationResampled does not upscale smaller images")
    func testJpegRepresentationResampledDoesNotUpscale() throws {
        let width = 200
        let height = 100
        let cgImage = try #require(createTestCGImage(width: width, height: height))
        let pngData = try #require(createPNGData(cgImage: cgImage))

        let resampled = try #require(
            PhotoAttachmentHelper.jpegRepresentationResampled(from: pngData, maxDimension: 4096)
        )
        let dimensions = try #require(decodedDimensions(of: resampled))

        #expect(dimensions.width == width)
        #expect(dimensions.height == height)
    }

    @Test("prepareForUpload respects custom maxDimension during transcode")
    func testPrepareForUploadRespectsCustomMaxDimensionDuringTranscode() async throws {
        let width = 5000
        let height = 3000
        let cgImage = try #require(createTestCGImage(width: width, height: height))
        // Use HEIC or TIFF which requires transcode
        let transcodeData = try #require(
            createHEICData(cgImage: cgImage) ?? createTIFFData(cgImage: cgImage)
        )
        #expect(PhotoAttachmentHelper.requiresJPEGTranscode(transcodeData))

        let prepared = try await PhotoAttachmentHelper.prepareForUpload(
            transcodeData,
            limit: 20_000_000,
            stripSensitiveMetadata: false,
            maxDimension: 1024
        )
        let dimensions = try #require(decodedDimensions(of: prepared.data))

        #expect(max(dimensions.width, dimensions.height) <= 1024)
        #expect(prepared.mimeType == "image/jpeg")
        #expect(prepared.fileExtension == "jpg")
    }

    @Test("prepareForUpload defaults to 4096px maxDimension during transcode")
    func testPrepareForUploadDefaultsTo4096DuringTranscode() async throws {
        let width = 5000
        let height = 3000
        let cgImage = try #require(createTestCGImage(width: width, height: height))
        let transcodeData = try #require(
            createHEICData(cgImage: cgImage) ?? createTIFFData(cgImage: cgImage)
        )

        let prepared = try await PhotoAttachmentHelper.prepareForUpload(
            transcodeData,
            limit: 20_000_000,
            stripSensitiveMetadata: false
        )
        let dimensions = try #require(decodedDimensions(of: prepared.data))

        #expect(max(dimensions.width, dimensions.height) <= 4096)
        #expect(prepared.mimeType == "image/jpeg")
    }
}
