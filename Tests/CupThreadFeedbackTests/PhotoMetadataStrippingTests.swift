import Foundation
import ImageIO
import Testing
@testable import CupThreadFeedback

@Suite("PhotoMetadataStripping")
struct PhotoMetadataStrippingTests {

    @Test func strippingSensitiveMetadataRemovesGPS() {
        guard let image = createTestImage(width: 100, height: 50) else {
            Issue.record("Failed to create test image")
            return
        }

        let gpsData: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 37.33,
            kCGImagePropertyGPSLongitude: -122.03
        ]
        let exifData: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: "2026:09:12 12:00:00"
        ]

        guard let inputData = createJPEGFixture(cgImage: image, orientation: 1, gps: gpsData, exif: exifData) else {
            Issue.record("Failed to create JPEG fixture with GPS")
            return
        }

        guard let strippedData = PhotoAttachmentHelper.strippingSensitiveMetadata(from: inputData) else {
            Issue.record("strippingSensitiveMetadata returned nil")
            return
        }

        guard let source = CGImageSourceCreateWithData(strippedData as CFData, nil) else {
            Issue.record("Failed to create image source from stripped data")
            return
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect(properties?[kCGImagePropertyGPSDictionary] == nil)
        #expect(properties?[kCGImagePropertyIPTCDictionary] == nil)

        let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] == nil)

        let pixelWidth = properties?[kCGImagePropertyPixelWidth] as? Int
        let pixelHeight = properties?[kCGImagePropertyPixelHeight] as? Int
        #expect(pixelWidth == 100)
        #expect(pixelHeight == 50)
    }

    @Test func strippedOutputStillSniffs() {
        guard let image = createTestImage(width: 80, height: 60) else {
            Issue.record("Failed to create test image")
            return
        }

        let gpsData: [CFString: Any] = [kCGImagePropertyGPSLatitude: 40.71]
        guard let jpegFixture = createJPEGFixture(cgImage: image, gps: gpsData),
              let strippedJPEG = PhotoAttachmentHelper.strippingSensitiveMetadata(from: jpegFixture) else {
            Issue.record("Failed to create or strip JPEG fixture")
            return
        }
        let jpegFormat = PhotoAttachmentHelper.sniffImageFormat(from: strippedJPEG)
        #expect(jpegFormat?.mimeType == "image/jpeg")
        #expect(jpegFormat?.fileExtension == "jpg")

        guard let pngFixture = createPNGFixture(cgImage: image),
              let strippedPNG = PhotoAttachmentHelper.strippingSensitiveMetadata(from: pngFixture) else {
            Issue.record("Failed to create or strip PNG fixture")
            return
        }
        let pngFormat = PhotoAttachmentHelper.sniffImageFormat(from: strippedPNG)
        #expect(pngFormat?.mimeType == "image/png")
        #expect(pngFormat?.fileExtension == "png")
    }

    @Test func strippingPreservesOrientation() {
        guard let image = createTestImage(width: 100, height: 50) else {
            Issue.record("Failed to create test image")
            return
        }

        // kCGImagePropertyOrientation = 6 is .right (90 deg CW)
        guard let rotatedFixture = createJPEGFixture(cgImage: image, orientation: 6) else {
            Issue.record("Failed to create rotated fixture")
            return
        }

        guard let strippedData = PhotoAttachmentHelper.strippingSensitiveMetadata(from: rotatedFixture) else {
            Issue.record("Failed to strip rotated fixture")
            return
        }

        guard let source = CGImageSourceCreateWithData(strippedData as CFData, nil) else {
            Issue.record("Failed to create source from stripped data")
            return
        }

        guard let decodedImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Issue.record("Failed to decode stripped image")
            return
        }

        // Width and height are swapped because orientation was baked into pixel buffer
        #expect(decodedImage.width == 50)
        #expect(decodedImage.height == 100)
    }

    @Test func strippingCorruptDataFailsClosed() {
        let corruptBytes = Data([0x01, 0x02, 0x03, 0x04])
        #expect(PhotoAttachmentHelper.strippingSensitiveMetadata(from: corruptBytes) == nil)
        #expect(PhotoAttachmentHelper.strippingSensitiveMetadata(from: Data()) == nil)

        let error = AttachmentValidationError.unprocessableImage
        #expect(error.errorDescription?.contains("processed") == true)
    }

    @Test func strippingMetadataFromPNGPassesLosslessly() {
        guard let image = createTestImage(width: 120, height: 80) else {
            Issue.record("Failed to create test image")
            return
        }

        guard let pngFixture = createPNGFixture(cgImage: image) else {
            Issue.record("Failed to create PNG fixture")
            return
        }

        guard let strippedData = PhotoAttachmentHelper.strippingSensitiveMetadata(from: pngFixture) else {
            Issue.record("Failed to strip PNG fixture")
            return
        }

        let format = PhotoAttachmentHelper.sniffImageFormat(from: strippedData)
        #expect(format?.mimeType == "image/png")

        guard let source = CGImageSourceCreateWithData(strippedData as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Issue.record("Failed to decode stripped PNG")
            return
        }
        #expect(decoded.width == 120)
        #expect(decoded.height == 80)
    }

    @Test func strippingMetadataFromHEICIfSupported() {
        let supportedTypes = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        guard supportedTypes.contains("public.heic") else {
            return
        }

        guard let image = createTestImage(width: 80, height: 80) else {
            Issue.record("Failed to create test image")
            return
        }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            "public.heic" as CFString,
            1,
            nil
        ) else {
            return
        }
        let props: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.33]
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }

        guard let stripped = PhotoAttachmentHelper.strippingSensitiveMetadata(from: mutableData as Data) else {
            Issue.record("Failed to strip HEIC")
            return
        }

        guard let source = CGImageSourceCreateWithData(stripped as CFData, nil) else {
            Issue.record("Failed to create source from stripped HEIC")
            return
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect(properties?[kCGImagePropertyGPSDictionary] == nil)
    }

    @MainActor
    @Test func feedbackComposerStripSensitiveMetadataConfiguration() {
        let client = makeClient()
        let defaultComposer = FeedbackComposerView(client: client)
        #expect(defaultComposer.stripSensitiveMetadata == true)

        let optOutComposer = FeedbackComposerView(client: client, stripSensitiveMetadata: false)
        #expect(optOutComposer.stripSensitiveMetadata == false)
    }

    @Test func strippingSensitiveMetadataPreservesAnimatedGIF() {
        guard let frame1 = createTestImage(width: 80, height: 60, red: 0.8, green: 0.2, blue: 0.2),
              let frame2 = createTestImage(width: 80, height: 60, red: 0.2, green: 0.8, blue: 0.2) else {
            Issue.record("Failed to create test images")
            return
        }

        guard let gifData = createGIFFixture(frames: [frame1, frame2], delayTimes: [0.5, 0.5]) else {
            Issue.record("Failed to create GIF fixture")
            return
        }

        guard let inputSource = CGImageSourceCreateWithData(gifData as CFData, nil) else {
            Issue.record("Failed to create image source from GIF fixture")
            return
        }
        #expect(CGImageSourceGetCount(inputSource) == 2)

        guard let stripped = PhotoAttachmentHelper.strippingSensitiveMetadata(from: gifData) else {
            Issue.record("strippingSensitiveMetadata returned nil for animated GIF")
            return
        }

        guard let outputSource = CGImageSourceCreateWithData(stripped as CFData, nil) else {
            Issue.record("Failed to create image source from stripped GIF")
            return
        }

        // Multi-frame animation must not be flattened to a single static frame (#85)
        #expect(CGImageSourceGetCount(outputSource) == 2)

        let format = PhotoAttachmentHelper.sniffImageFormat(from: stripped)
        #expect(format?.mimeType == "image/gif")
        #expect(format?.fileExtension == "gif")

        let frameProperties = CGImageSourceCopyPropertiesAtIndex(outputSource, 0, nil) as? [CFString: Any]
        let gifDict = frameProperties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = (gifDict?[kCGImagePropertyGIFDelayTime] as? Double)
            ?? (gifDict?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
        #expect(delay == 0.5)
    }

    @Test func strippingSensitiveMetadataPreservesAnimatedWebP() {
        // ImageIO on Apple platforms includes the WebP reader (org.webmproject.webp) but no
        // destination encoder in CGImageDestinationCopyTypeIdentifiers(). We verify with a minimal
        // 2-frame animated WebP container to assert that multi-frame WebP is preserved intact
        // without flattening to a still image or falling back to single-frame PNG/JPEG (#85).
        let webpData = createAnimatedWebPFixture()

        guard let inputSource = CGImageSourceCreateWithData(webpData as CFData, nil) else {
            Issue.record("Failed to create image source from animated WebP fixture")
            return
        }
        #expect(CGImageSourceGetCount(inputSource) == 2)

        guard let stripped = PhotoAttachmentHelper.strippingSensitiveMetadata(from: webpData) else {
            Issue.record("strippingSensitiveMetadata returned nil for animated WebP")
            return
        }

        guard let outputSource = CGImageSourceCreateWithData(stripped as CFData, nil) else {
            Issue.record("Failed to create image source from stripped WebP")
            return
        }

        #expect(CGImageSourceGetCount(outputSource) == 2)

        let format = PhotoAttachmentHelper.sniffImageFormat(from: stripped)
        #expect(format?.mimeType == "image/webp")
        #expect(format?.fileExtension == "webp")
    }

    // MARK: - Test Fixture Helpers

    private func createTestImage(
        width: Int = 100,
        height: Int = 50,
        red: CGFloat = 0.2,
        green: CGFloat = 0.5,
        blue: CGFloat = 0.8
    ) -> CGImage? {
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
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func createGIFFixture(
        frames: [CGImage],
        delayTimes: [Double] = [0.5, 0.5]
    ) -> Data? {
        guard !frames.isEmpty, frames.count == delayTimes.count else { return nil }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            "com.compuserve.gif" as CFString,
            frames.count,
            nil
        ) else {
            return nil
        }
        for (index, frame) in frames.enumerated() {
            let frameProperties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delayTimes[index]
                ]
            ]
            CGImageDestinationAddImage(dest, frame, frameProperties as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    private func createAnimatedWebPFixture() -> Data {
        // Minimal 2-frame 10x10 animated WebP image (204 bytes) with VP8X, ANIM, and two ANMF chunks.
        let hexChunks = [
            "52494646c400000057454250565038580a00000002000000090000090000414e494d060000000000",
            "00000000414e4d464a000000000000000000090000090000f401000256503820320000003001009d",
            "012a0a000a0001402625a000037000fef2eb7ffff9b03ff6f3ff047a01ffffd2e0fffe9707fff4b8",
            "3ff4a4000000414e4d4646000000000000000000090000090000f4010000565038202e0000003401",
            "009d012a0a000a0000002625a000037000fefb55e3ffff4b83fffa5c1fffd2e0ffd2e0fffad5e557",
            "acaba000"
        ]
        let hex = hexChunks.joined()
        var data = Data()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            if let byte = UInt8(hex[idx..<next], radix: 16) {
                data.append(byte)
            }
            idx = next
        }
        return data
    }

    private func createJPEGFixture(
        cgImage: CGImage,
        orientation: UInt32? = nil,
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
        var properties: [CFString: Any] = [:]
        if let orientation {
            properties[kCGImagePropertyOrientation] = orientation
        }
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
}
