import Foundation
import ImageIO
import Testing
@testable import CupThreadFeedback

// swiftlint:disable file_length
@Suite("PhotoMetadataStripping")
// swiftlint:disable:next type_body_length
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

    @Test func jpegRepresentationResampledPreservesOrientationForRotatedImage() {
        guard let image = createTestImage(width: 100, height: 50) else {
            Issue.record("Failed to create test image")
            return
        }

        // kCGImagePropertyOrientation = 6 is .right (90 deg CW)
        guard let rotatedFixture = createJPEGFixture(cgImage: image, orientation: 6) else {
            Issue.record("Failed to create rotated fixture")
            return
        }

        guard let transcodedData = PhotoAttachmentHelper.jpegRepresentationResampled(from: rotatedFixture) else {
            Issue.record("Failed to transcode rotated fixture")
            return
        }

        guard let source = CGImageSourceCreateWithData(transcodedData as CFData, nil) else {
            Issue.record("Failed to create source from transcoded data")
            return
        }

        guard let decodedImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Issue.record("Failed to decode transcoded image")
            return
        }

        // Orientation was baked into pixel buffer, matching strippingPreservesOrientation
        #expect(decodedImage.width == 50)
        #expect(decodedImage.height == 100)

        // Output orientation should be absent or 1 (upright)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let outputOrientation = properties?[kCGImagePropertyOrientation] as? UInt32
        #expect(outputOrientation == nil || outputOrientation == 1)
    }

    @Test func jpegRepresentationResampledKeepsUnswappedDimensionsForOrientation1() {
        guard let image = createTestImage(width: 100, height: 50) else {
            Issue.record("Failed to create test image")
            return
        }

        guard let fixture = createJPEGFixture(cgImage: image, orientation: 1) else {
            Issue.record("Failed to create fixture with orientation 1")
            return
        }

        guard let transcodedData = PhotoAttachmentHelper.jpegRepresentationResampled(from: fixture) else {
            Issue.record("Failed to transcode fixture")
            return
        }

        guard let source = CGImageSourceCreateWithData(transcodedData as CFData, nil) else {
            Issue.record("Failed to create source from transcoded data")
            return
        }

        guard let decodedImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Issue.record("Failed to decode transcoded image")
            return
        }

        #expect(decodedImage.width == 100)
        #expect(decodedImage.height == 50)

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let outputOrientation = properties?[kCGImagePropertyOrientation] as? UInt32
        #expect(outputOrientation == nil || outputOrientation == 1)
    }

    @Test func jpegRepresentationResampledPreservesHEICOrientationIfSupported() {
        guard let image = createTestImage(width: 100, height: 50),
              let heicFixture = createHEICFixture(cgImage: image, orientation: 6) else {
            // HEIC destination encoding not supported on this platform
            return
        }

        guard let transcodedData = PhotoAttachmentHelper.jpegRepresentationResampled(from: heicFixture) else {
            Issue.record("Failed to transcode HEIC fixture")
            return
        }

        let sniffed = PhotoAttachmentHelper.sniffImageFormat(from: transcodedData)
        #expect(sniffed?.mimeType == "image/jpeg")

        guard let source = CGImageSourceCreateWithData(transcodedData as CFData, nil),
              let decodedImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Issue.record("Failed to decode transcoded JPEG from HEIC")
            return
        }

        // Dimensions must be swapped (portrait upright)
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

    @Test @MainActor func feedbackComposerStripSensitiveMetadataConfiguration() {
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

    @Test func strippingSensitiveMetadataRemovesGPSFromMultiFrameContainer() {
        guard let frame1 = createTestImage(width: 80, height: 60, red: 0.8, green: 0.2, blue: 0.2),
              let frame2 = createTestImage(width: 80, height: 60, red: 0.2, green: 0.8, blue: 0.2) else {
            Issue.record("Failed to create test images")
            return
        }

        let gpsData: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 37.7749,
            kCGImagePropertyGPSLongitude: -122.4194
        ]
        let exifData: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: "2026:09:26 12:00:00"
        ]

        guard let multiFrameFixture = createMultiFrameTIFFFixture(
            frames: [frame1, frame2],
            gps: gpsData,
            exif: exifData
        ) else {
            Issue.record("Failed to create multi-frame TIFF fixture")
            return
        }

        guard let inputSource = CGImageSourceCreateWithData(multiFrameFixture as CFData, nil) else {
            Issue.record("Failed to create image source from fixture")
            return
        }
        #expect(CGImageSourceGetCount(inputSource) == 2)

        guard let stripped = PhotoAttachmentHelper.strippingSensitiveMetadata(from: multiFrameFixture) else {
            Issue.record("strippingSensitiveMetadata returned nil for multi-frame fixture")
            return
        }

        guard let outputSource = CGImageSourceCreateWithData(stripped as CFData, nil) else {
            Issue.record("Failed to create image source from stripped multi-frame fixture")
            return
        }

        // Multi-frame non-animated containers must be sanitized to a single frame
        #expect(CGImageSourceGetCount(outputSource) == 1)

        let properties = CGImageSourceCopyPropertiesAtIndex(outputSource, 0, nil) as? [CFString: Any]
        #expect(properties?[kCGImagePropertyGPSDictionary] == nil)
        #expect(properties?[kCGImagePropertyIPTCDictionary] == nil)
        let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] == nil)
    }

    @Test func strippingSensitiveMetadataRemovesGPSFromMultiFrameHEIC() {
        guard let frame1 = createTestImage(width: 80, height: 60, red: 0.8, green: 0.2, blue: 0.2),
              let frame2 = createTestImage(width: 80, height: 60, red: 0.2, green: 0.8, blue: 0.2) else {
            Issue.record("Failed to create test images")
            return
        }

        let gpsData: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 37.7749,
            kCGImagePropertyGPSLongitude: -122.4194
        ]

        guard let multiFrameHEIC = createMultiFrameHEICFixture(
            frames: [frame1, frame2],
            gps: gpsData
        ) else {
            // HEIC encoding may not be available on all platforms
            return
        }

        guard let inputSource = CGImageSourceCreateWithData(multiFrameHEIC as CFData, nil) else {
            Issue.record("Failed to create image source from HEIC fixture")
            return
        }
        #expect(CGImageSourceGetCount(inputSource) == 2)

        guard let stripped = PhotoAttachmentHelper.strippingSensitiveMetadata(from: multiFrameHEIC) else {
            Issue.record("strippingSensitiveMetadata returned nil for multi-frame HEIC")
            return
        }

        guard let outputSource = CGImageSourceCreateWithData(stripped as CFData, nil) else {
            Issue.record("Failed to create image source from stripped HEIC")
            return
        }

        #expect(CGImageSourceGetCount(outputSource) == 1)
        let properties = CGImageSourceCopyPropertiesAtIndex(outputSource, 0, nil) as? [CFString: Any]
        #expect(properties?[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test func isAnimatedImageContainerIdentifiesAnimatedFormats() {
        guard let frame1 = createTestImage(width: 40, height: 40),
              let frame2 = createTestImage(width: 40, height: 40) else {
            Issue.record("Failed to create test images")
            return
        }

        // Animated GIF
        guard let gifData = createGIFFixture(frames: [frame1, frame2]),
              let gifSource = CGImageSourceCreateWithData(gifData as CFData, nil) else {
            Issue.record("Failed to create GIF fixture")
            return
        }
        #expect(PhotoAttachmentHelper.isAnimatedImageContainer(source: gifSource, data: gifData))

        // Animated WebP
        let webpData = createAnimatedWebPFixture()
        guard let webpSource = CGImageSourceCreateWithData(webpData as CFData, nil) else {
            Issue.record("Failed to create WebP fixture")
            return
        }
        #expect(PhotoAttachmentHelper.isAnimatedImageContainer(source: webpSource, data: webpData))

        // Non-animated single-frame JPEG
        guard let jpegData = createJPEGFixture(cgImage: frame1),
              let jpegSource = CGImageSourceCreateWithData(jpegData as CFData, nil) else {
            Issue.record("Failed to create JPEG fixture")
            return
        }
        #expect(!PhotoAttachmentHelper.isAnimatedImageContainer(source: jpegSource, data: jpegData))

        // Non-animated multi-frame TIFF
        guard let tiffData = createMultiFrameTIFFFixture(frames: [frame1, frame2]),
              let tiffSource = CGImageSourceCreateWithData(tiffData as CFData, nil) else {
            Issue.record("Failed to create TIFF fixture")
            return
        }
        #expect(!PhotoAttachmentHelper.isAnimatedImageContainer(source: tiffSource, data: tiffData))
    }

    // MARK: - Animated Container Metadata (SEC-10)

    @Test func strippingSensitiveMetadataRemovesEXIFChunkFromAnimatedWebP() {
        let gpsMarker = "SEC10 GPS 37.7749 -122.4194"
        let fixture = createAnimatedWebPFixtureWithEXIFChunk(gpsMarker: gpsMarker)

        // The fixture really carries the GPS EXIF payload and animates.
        #expect(fixture.data.range(of: Data(gpsMarker.utf8)) != nil)
        guard let inputSource = CGImageSourceCreateWithData(fixture.data as CFData, nil) else {
            Issue.record("Failed to create image source from WebP EXIF fixture")
            return
        }
        #expect(CGImageSourceGetCount(inputSource) == 2)

        guard let stripped = PhotoAttachmentHelper.strippingSensitiveMetadata(from: fixture.data) else {
            Issue.record("strippingSensitiveMetadata returned nil for EXIF-carrying animated WebP")
            return
        }

        // The GPS EXIF payload must be gone...
        #expect(stripped.range(of: Data(gpsMarker.utf8)) == nil)
        // ...exactly the EXIF chunk removed and nothing else...
        #expect(stripped.count == fixture.data.count - fixture.exifChunkByteCount)
        // ...the VP8X EXIF flag cleared back to animation-only...
        let bytes = [UInt8](stripped)
        #expect(bytes.count > 20)
        #expect(bytes[20] == 0x02)
        // ...and the rewritten container must still animate with both frames.
        guard let outputSource = CGImageSourceCreateWithData(stripped as CFData, nil) else {
            Issue.record("Stripped WebP is no longer decodable")
            return
        }
        #expect(CGImageSourceGetCount(outputSource) == 2)

        let format = PhotoAttachmentHelper.sniffImageFormat(from: stripped)
        #expect(format?.mimeType == "image/webp")
        #expect(format?.fileExtension == "webp")
    }

    @Test func strippingSensitiveMetadataRemovesMetadataExtensionsFromAnimatedGIF() {
        let gpsMarker = "SEC10 GPS 37.7749 -122.4194"
        let commentMarker = "SEC10 made-by TestTool (user@example.com)"
        let xmpMarker = "SEC10 <x:xmpmeta>37.7749</x:xmpmeta>"
        guard let fixture = createAnimatedGIFWithMetadataExtensions(
            gpsMarker: gpsMarker,
            commentMarker: commentMarker,
            xmpMarker: xmpMarker
        ) else {
            Issue.record("Failed to create GIF metadata fixture")
            return
        }

        #expect(fixture.data.range(of: Data(gpsMarker.utf8)) != nil)
        #expect(fixture.data.range(of: Data(commentMarker.utf8)) != nil)
        #expect(fixture.data.range(of: Data(xmpMarker.utf8)) != nil)

        guard let stripped = PhotoAttachmentHelper.strippingSensitiveMetadata(from: fixture.data) else {
            Issue.record("strippingSensitiveMetadata returned nil for metadata-carrying animated GIF")
            return
        }

        // EXIF, XMP, and comment extension payloads must all be gone...
        #expect(stripped.range(of: Data(gpsMarker.utf8)) == nil)
        #expect(stripped.range(of: Data(commentMarker.utf8)) == nil)
        #expect(stripped.range(of: Data(xmpMarker.utf8)) == nil)
        // ...exactly the three extension blocks removed and nothing else...
        #expect(stripped.count == fixture.data.count - fixture.insertedByteCount)
        // ...with loop control (if the encoder wrote one) preserved.
        let hadLoopExtension = fixture.data.range(of: Data("NETSCAPE2.0".utf8)) != nil
        #expect((stripped.range(of: Data("NETSCAPE2.0".utf8)) != nil) == hadLoopExtension)

        // The rewritten container must still animate with unchanged timing.
        guard let outputSource = CGImageSourceCreateWithData(stripped as CFData, nil) else {
            Issue.record("Stripped GIF is no longer decodable")
            return
        }
        #expect(CGImageSourceGetCount(outputSource) == 2)
        let frameProperties = CGImageSourceCopyPropertiesAtIndex(outputSource, 0, nil) as? [CFString: Any]
        let gifDict = frameProperties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = (gifDict?[kCGImagePropertyGIFDelayTime] as? Double)
            ?? (gifDict?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
        #expect(delay == 0.5)

        let format = PhotoAttachmentHelper.sniffImageFormat(from: stripped)
        #expect(format?.mimeType == "image/gif")
        #expect(format?.fileExtension == "gif")
    }

    @Test func strippingSensitiveMetadataLeavesCleanAnimatedContainersByteIdentical() {
        guard let frame1 = createTestImage(width: 80, height: 60, red: 0.8, green: 0.2, blue: 0.2),
              let frame2 = createTestImage(width: 80, height: 60, red: 0.2, green: 0.8, blue: 0.2),
              let gifFixture = createGIFFixture(frames: [frame1, frame2], delayTimes: [0.5, 0.5]) else {
            Issue.record("Failed to create animated fixtures")
            return
        }

        // Containers without metadata chunks keep the #85 byte-identical pass-through.
        #expect(PhotoAttachmentHelper.strippingSensitiveMetadata(from: gifFixture) == gifFixture)
        #expect(PhotoAttachmentHelper.strippingSensitiveMetadata(from: createAnimatedWebPFixture()) == createAnimatedWebPFixture())
    }

    @Test func prepareForUploadStripsAnimatedWebPGPSMetadata() async throws {
        let gpsMarker = "SEC10 GPS 37.7749 -122.4194"
        let fixture = createAnimatedWebPFixtureWithEXIFChunk(gpsMarker: gpsMarker).data

        let prepared = try await PhotoAttachmentHelper.prepareForUpload(
            fixture,
            limit: PhotoAttachmentHelper.defaultMaxAttachmentBytes,
            stripSensitiveMetadata: true
        )

        #expect(prepared.mimeType == "image/webp")
        #expect(prepared.fileExtension == "webp")
        #expect(prepared.data.range(of: Data(gpsMarker.utf8)) == nil)
        guard let source = CGImageSourceCreateWithData(prepared.data as CFData, nil) else {
            Issue.record("Failed to parse prepared WebP")
            return
        }
        #expect(CGImageSourceGetCount(source) == 2)
    }

    @Test func animatedContainerMetadataWalkerReportsCleanContainers() {
        #expect(PhotoAttachmentHelper.stripAnimatedContainerMetadata(from: createAnimatedWebPFixture()) == .clean)

        guard let frame1 = createTestImage(width: 40, height: 40),
              let frame2 = createTestImage(width: 40, height: 40),
              let gifFixture = createGIFFixture(frames: [frame1, frame2]) else {
            Issue.record("Failed to create GIF fixture")
            return
        }
        #expect(PhotoAttachmentHelper.stripAnimatedContainerMetadata(from: gifFixture) == .clean)

        #expect(PhotoAttachmentHelper.isMetadataApplicationIdentifier(Array("NETSCAPE2.0\0\0".utf8)) == false)
        #expect(PhotoAttachmentHelper.isMetadataApplicationIdentifier(Array("ANIMEXTS1.0\0\0".utf8)) == false)
        #expect(PhotoAttachmentHelper.isMetadataApplicationIdentifier(Array("Exif\0\0\0\0\0\0\0".utf8)) == true)
        #expect(PhotoAttachmentHelper.isMetadataApplicationIdentifier(Array("exif\0\0\0\0\0\0\0".utf8)) == true)
        #expect(PhotoAttachmentHelper.isMetadataApplicationIdentifier(Array("XMP DataXMP".utf8)) == true)
        #expect(PhotoAttachmentHelper.isMetadataApplicationIdentifier([]) == false)
    }

    @Test func animatedContainerMetadataWalkerFailsClosedOnMalformedContainers() {
        // WebP: RIFF chunk list cut off mid-header.
        let webpFixture = createAnimatedWebPFixture()
        #expect(PhotoAttachmentHelper.stripWebPContainerMetadata(from: webpFixture.prefix(20)) == .unsafe)

        // WebP: chunk size field overrunning the container.
        var overrun = [UInt8](webpFixture)
        overrun[16] = 0xFF
        overrun[17] = 0xFF
        overrun[18] = 0xFF
        #expect(PhotoAttachmentHelper.stripWebPContainerMetadata(from: Data(overrun)) == .unsafe)

        // WebP: not WebP bytes at all.
        #expect(PhotoAttachmentHelper.stripWebPContainerMetadata(from: Data(repeating: 0x00, count: 32)) == .unsafe)

        // GIF: block introducer that is neither extension, image, nor trailer.
        guard let frame1 = createTestImage(width: 40, height: 40),
              let frame2 = createTestImage(width: 40, height: 40),
              let gifFixture = createGIFFixture(frames: [frame1, frame2]) else {
            Issue.record("Failed to create GIF fixture")
            return
        }
        var unknownBlock = [UInt8](gifFixture)
        unknownBlock[firstBlockOffset(in: unknownBlock)] = 0x00
        #expect(PhotoAttachmentHelper.stripGIFContainerMetadata(from: Data(unknownBlock)) == .unsafe)

        // GIF: application extension whose first sub-block claims more bytes
        // than the container holds (deterministic hand-built structure).
        var malformedGIF: [UInt8] = Array("GIF89a".utf8)
        malformedGIF += [0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00] // 1x1 logical screen, no GCT
        malformedGIF += [0x21, 0xFF, 0x20] // app extension, first sub-block claims 32 bytes
        malformedGIF += Array(repeating: 0x41, count: 8) // only 8 present before EOF
        #expect(PhotoAttachmentHelper.stripGIFContainerMetadata(from: Data(malformedGIF)) == .unsafe)
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

    /// The animated WebP fixture spliced with a top-level `EXIF` RIFF chunk
    /// carrying a GPS TIFF payload, mirroring what `cwebp -metadata exif`
    /// produces: the chunk sits after `VP8X` and the VP8X EXIF flag bit is
    /// set alongside the animation bit.
    private func createAnimatedWebPFixtureWithEXIFChunk(gpsMarker: String) -> (data: Data, exifChunkByteCount: Int) {
        var bytes = [UInt8](createAnimatedWebPFixture())
        // VP8X flags byte sits at offset 20 (RIFF header 12 + chunk header 8):
        // set the EXIF-present bit (0x08) alongside the animation bit (0x02).
        bytes[20] |= 0x08

        var chunk: [UInt8] = Array("EXIF".utf8)
        let payload = exifTIFFPayloadWithGPSMarker(gpsMarker)
        chunk += [UInt8(truncatingIfNeeded: payload.count), 0, 0, 0] // little-endian size
        chunk += payload
        if payload.count % 2 == 1 { chunk.append(0x00) } // RIFF pad byte
        bytes.insert(contentsOf: chunk, at: 30) // immediately after the VP8X chunk (12 + 8 + 10)

        let riffSize = UInt32(bytes.count - 8)
        bytes[4] = UInt8(truncatingIfNeeded: riffSize)
        bytes[5] = UInt8(truncatingIfNeeded: riffSize >> 8)
        bytes[6] = UInt8(truncatingIfNeeded: riffSize >> 16)
        bytes[7] = UInt8(truncatingIfNeeded: riffSize >> 24)
        return (Data(bytes), chunk.count)
    }

    /// Minimal little-endian TIFF carrying a GPS IFD, followed by a unique
    /// ASCII marker: the shape a WebP `EXIF` chunk stores in (the same GPS
    /// data the JPEG fixtures embed via ImageIO).
    private func exifTIFFPayloadWithGPSMarker(_ marker: String) -> [UInt8] {
        var tiff: [UInt8] = [0x49, 0x49, 0x2A, 0x00] // "II", TIFF magic 42
        tiff += [0x08, 0x00, 0x00, 0x00] // IFD0 at offset 8
        tiff += [0x01, 0x00] // one IFD0 entry
        tiff += [0x25, 0x88] // tag 0x8825 (GPSInfo)
        tiff += [0x04, 0x00] // type LONG
        tiff += [0x01, 0x00, 0x00, 0x00] // count 1
        tiff += [0x1A, 0x00, 0x00, 0x00] // GPS IFD at offset 26
        tiff += [0x00, 0x00, 0x00, 0x00] // no next IFD (offset 26 reached)
        tiff += [0x02, 0x00] // two GPS IFD entries
        tiff += [0x01, 0x00, 0x02, 0x00, 0x02, 0x00, 0x00, 0x00, 0x4E, 0x00, 0x00, 0x00] // GPSLatitudeRef "N"
        tiff += [0x02, 0x00, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x38, 0x00, 0x00, 0x00] // GPSLatitude RATIONAL @ 56
        tiff += [0x00, 0x00, 0x00, 0x00] // no next IFD (offset 56 reached)
        tiff += [0x25, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00] // 37/1 degrees (offsets 56..<64)
        tiff += Array(marker.utf8) // unique search marker inside the chunk
        return tiff
    }

    /// A 2-frame animated GIF spliced with EXIF and XMP application
    /// extensions plus a comment extension, placed where mainstream encoders
    /// write them: between the screen descriptor and the first image block.
    private func createAnimatedGIFWithMetadataExtensions(
        gpsMarker: String,
        commentMarker: String,
        xmpMarker: String
    ) -> (data: Data, insertedByteCount: Int)? {
        guard let frame1 = createTestImage(width: 80, height: 60, red: 0.8, green: 0.2, blue: 0.2),
              let frame2 = createTestImage(width: 80, height: 60, red: 0.2, green: 0.8, blue: 0.2),
              let gif = createGIFFixture(frames: [frame1, frame2], delayTimes: [0.5, 0.5]) else {
            return nil
        }
        var bytes = [UInt8](gif)

        func applicationExtension(identifier: [UInt8], payloadMarker: String) -> [UInt8] {
            let identifierBlock = identifier + [UInt8](repeating: 0x00, count: max(0, 11 - identifier.count))
            let payload = Array(payloadMarker.utf8)
            return [0x21, 0xFF, UInt8(identifierBlock.count)] + identifierBlock
                + [UInt8(payload.count)] + payload + [0x00]
        }

        let exifExtension = applicationExtension(identifier: Array("Exif".utf8), payloadMarker: gpsMarker)
        let xmpExtension = applicationExtension(identifier: Array("XMP DataXMP".utf8), payloadMarker: xmpMarker)
        let comment: [UInt8] = [0x21, 0xFE, UInt8(commentMarker.utf8.count)] + Array(commentMarker.utf8) + [0x00]
        let inserted = exifExtension + xmpExtension + comment
        bytes.insert(contentsOf: inserted, at: firstBlockOffset(in: bytes))
        return (Data(bytes), inserted.count)
    }

    /// Offset of the first block after the header, logical screen descriptor,
    /// and optional global color table.
    private func firstBlockOffset(in bytes: [UInt8]) -> Int {
        var offset = 13
        let packed = bytes[10]
        if packed & 0x80 != 0 {
            offset += 3 * (1 << (Int(packed & 0x07) + 1))
        }
        return offset
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

    private func createHEICFixture(
        cgImage: CGImage,
        orientation: UInt32? = nil
    ) -> Data? {
        let supportedTypes = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        guard supportedTypes.contains("public.heic") else {
            return nil
        }
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
        if let orientation {
            properties[kCGImagePropertyOrientation] = orientation
        }
        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    private func createMultiFrameTIFFFixture(
        frames: [CGImage],
        gps: [CFString: Any]? = nil,
        exif: [CFString: Any]? = nil
    ) -> Data? {
        guard !frames.isEmpty else { return nil }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            "public.tiff" as CFString,
            frames.count,
            nil
        ) else {
            return nil
        }
        for (index, frame) in frames.enumerated() {
            var properties: [CFString: Any] = [:]
            if index == 0 {
                if let gps { properties[kCGImagePropertyGPSDictionary] = gps }
                if let exif { properties[kCGImagePropertyExifDictionary] = exif }
            }
            CGImageDestinationAddImage(dest, frame, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    private func createMultiFrameHEICFixture(
        frames: [CGImage],
        gps: [CFString: Any]? = nil,
        exif: [CFString: Any]? = nil
    ) -> Data? {
        let supportedTypes = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        guard supportedTypes.contains("public.heic"), !frames.isEmpty else {
            return nil
        }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            "public.heic" as CFString,
            frames.count,
            nil
        ) else {
            return nil
        }
        for (index, frame) in frames.enumerated() {
            var properties: [CFString: Any] = [:]
            if index == 0 {
                if let gps { properties[kCGImagePropertyGPSDictionary] = gps }
                if let exif { properties[kCGImagePropertyExifDictionary] = exif }
            }
            CGImageDestinationAddImage(dest, frame, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }
}
