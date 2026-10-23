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

    // MARK: - Metadata-strip decode bound (PERF-6, #519)

    @Test("strippingSensitiveMetadata refuses a 20000x20000 canvas without decoding it")
    func testStrippingRefusesHugeDeclaredCanvas() throws {
        let bomb = try #require(Self.decompressionBombPNG)

        // The fixture is a real PNG: a capped decode proves the container
        // parses, so the refusal below comes from the pixel bound and not from
        // a malformed file. A native-size decode would need ~1.6 GB of RGBA.
        let capped = try #require(thumbnail(of: bomb, maxPixelSize: 64))
        #expect(capped.width == 64)
        #expect(capped.height == 64)

        let source = try #require(CGImageSourceCreateWithData(bomb as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let declaredWidth = properties?[kCGImagePropertyPixelWidth] as? Int
        let declaredHeight = properties?[kCGImagePropertyPixelHeight] as? Int
        #expect(declaredWidth == 20_000)
        #expect(declaredHeight == 20_000)
        #expect((declaredWidth ?? 0) * (declaredHeight ?? 0) > PhotoAttachmentHelper.maxDecodedPixelCount)

        #expect(PhotoAttachmentHelper.exceedsDecodeBound(source))
        #expect(PhotoAttachmentHelper.strippingSensitiveMetadata(from: bomb) == nil)
    }

    @Test("prepareForUpload surfaces unprocessableImage for a huge-canvas PNG")
    func testPrepareForUploadRefusesHugeCanvasPNG() async throws {
        let bomb = try #require(Self.decompressionBombPNG)

        await #expect(throws: AttachmentValidationError.unprocessableImage) {
            _ = try await PhotoAttachmentHelper.prepareForUpload(
                bomb,
                limit: 20_000_000,
                stripSensitiveMetadata: true
            )
        }
    }

    @Test("prepareForUpload passes a huge-canvas image through untouched when stripping is off")
    func testPrepareForUploadPassesHugeCanvasThroughWithoutStripping() async throws {
        let bomb = try #require(Self.decompressionBombPNG)

        let prepared = try await PhotoAttachmentHelper.prepareForUpload(
            bomb,
            limit: 20_000_000,
            stripSensitiveMetadata: false
        )

        // No decode happens on this path, so the documented escape hatch for
        // images above the strip bound stays available to hosts.
        #expect(prepared.data == bomb)
        #expect(prepared.mimeType == "image/png")
    }

    @Test("strippingSensitiveMetadata preserves pixel dimensions of ordinary photos")
    func testStrippingPreservesPixelDimensions() throws {
        let cgImage = try #require(createTestCGImage(width: 2000, height: 1500))
        let jpeg = try #require(createJPEGData(cgImage: cgImage))

        let stripped = try #require(PhotoAttachmentHelper.strippingSensitiveMetadata(from: jpeg))
        let dimensions = try #require(decodedDimensions(of: stripped))

        #expect(dimensions.width == 2000)
        #expect(dimensions.height == 1500)
    }

    @Test("exceedsDecodeBound fails closed when the container declares no dimensions")
    func testExceedsDecodeBoundFailsClosedWithoutDimensions() throws {
        let stub = PNGFixture.makeDimensionlessPNG(width: 20_000, height: 20_000)
        let source = try #require(CGImageSourceCreateWithData(stub as CFData, nil))

        #expect(PhotoAttachmentHelper.exceedsDecodeBound(source))
        #expect(PhotoAttachmentHelper.strippingSensitiveMetadata(from: stub) == nil)
    }

    @Test("prepareForUpload treats an explicit nil maxDimension as the default 4096 cap")
    func testPrepareForUploadNormalizesNilMaxDimensionDuringTranscode() async throws {
        let cgImage = try #require(createTestCGImage(width: 5000, height: 3000))
        // TIFF is not an upload format, so the bytes always reach the JPEG
        // transcode. The limit is raised above the uncompressed fixture size so
        // the pass-under-test runs instead of the earlier downscale branch,
        // which already normalized the cap.
        let transcodeData = try #require(createTIFFData(cgImage: cgImage))
        #expect(PhotoAttachmentHelper.requiresJPEGTranscode(transcodeData))

        let prepared = try await PhotoAttachmentHelper.prepareForUpload(
            transcodeData,
            limit: 100_000_000,
            stripSensitiveMetadata: false,
            maxDimension: nil
        )
        let dimensions = try #require(decodedDimensions(of: prepared.data))

        // A forwarded `nil` used to mean "unconstrained" for the JPEG
        // transcode, which decoded 5000px sources at native size.
        #expect(max(dimensions.width, dimensions.height) <= 4096)
        #expect(max(dimensions.width, dimensions.height) > 1024)
    }

    /// A valid 20 000 x 20 000 1-bit grayscale PNG: ~48 KB on disk, while a
    /// native-size RGBA decode needs ~1.6 GB.
    private static let decompressionBombPNG = PNGFixture.makeHugeCanvasPNG(width: 20_000, height: 20_000)

    private func thumbnail(of data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary)
    }

    private func createJPEGData(cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Builds PNG containers by hand so tests can describe canvases far larger
/// than anything they could afford to allocate (PERF-6).
private enum PNGFixture {
    /// A valid PNG whose header declares `width` x `height` pixels.
    ///
    /// Encoded as 1-bit grayscale with zeroed scanlines, so a 20 000 x 20 000
    /// canvas compresses to roughly 48 KB: small enough to keep the fixture
    /// cheap, while a native-size RGBA decode would need gigabytes.
    static func makeHugeCanvasPNG(width: Int, height: Int) -> Data? {
        let bytesPerRow = (width + 7) / 8
        let scanlines = Data(count: height * (1 + bytesPerRow))
        guard let idat = try? (scanlines as NSData).compressed(using: .zlib) as Data else {
            return nil
        }
        let header = dimensionsPayload(width: width, height: height)
            + Data([1, 0, 0, 0, 0]) // bit depth 1, grayscale, deflate, adaptive filter, no interlace
        return container(header: header, idat: idat)
    }

    /// A PNG whose header declares `width` x `height` but whose payload cannot
    /// be decoded: ImageIO parses the container but reports no dimensions.
    static func makeDimensionlessPNG(width: Int, height: Int) -> Data {
        let header = dimensionsPayload(width: width, height: height)
            + Data([8, 2, 0, 0, 0]) // bit depth 8, RGB, deflate, adaptive filter, no interlace
        let stubIDAT = Data([0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01])
        return container(header: header, idat: stubIDAT)
    }

    private static func dimensionsPayload(width: Int, height: Int) -> Data {
        var payload = Data()
        var bigWidth = UInt32(width).bigEndian
        var bigHeight = UInt32(height).bigEndian
        withUnsafeBytes(of: &bigWidth) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &bigHeight) { payload.append(contentsOf: $0) }
        return payload
    }

    private static func container(header: Data, idat: Data) -> Data {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(chunk("IHDR", header))
        png.append(chunk("IDAT", idat))
        png.append(chunk("IEND", Data()))
        return png
    }

    private static func chunk(_ type: String, _ payload: Data) -> Data {
        var chunk = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { chunk.append(contentsOf: $0) }
        let typeBytes = Data(type.utf8)
        chunk.append(typeBytes)
        chunk.append(payload)
        var checksum = crc32(typeBytes + payload).bigEndian
        withUnsafeBytes(of: &checksum) { chunk.append(contentsOf: $0) }
        return chunk
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var checksum: UInt32 = 0xFFFF_FFFF
        for byte in data {
            checksum = crcTable[Int((checksum ^ UInt32(byte)) & 0xFF)] ^ (checksum >> 8)
        }
        return checksum ^ 0xFFFF_FFFF
    }
}
