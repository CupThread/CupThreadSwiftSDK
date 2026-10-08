import Foundation
import ImageIO
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Errors encountered during local validation of an attachment before upload.
public enum AttachmentValidationError: LocalizedError, Equatable, Sendable {
    /// The attachment exceeds the app's maximum allowed upload size.
    case oversized(size: Int, limit: Int)
    /// The attachment could not be processed or stripped of sensitive metadata.
    case unprocessableImage
    /// The attachment's format is not accepted by the upload API (HTTP 415) —
    /// e.g. SVG, which the server rejects for stored-XSS reasons. The upload
    /// API accepts PNG, JPEG, WebP, and GIF only.
    case unsupportedType

    public var errorDescription: String? {
        switch self {
        case .oversized(let size, let limit):
            let formattedLimit = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
            let formattedSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            return "Attachment (\(formattedSize)) exceeds the maximum allowed size of \(formattedLimit)."
        case .unprocessableImage:
            return "The selected photo could not be processed for upload."
        case .unsupportedType:
            return "That image type isn't supported. Please attach a PNG, JPEG, WebP, or GIF."
        }
    }
}

/// Helper methods for deriving representation formats, filenames, and validation rules for attachments.
public enum PhotoAttachmentHelper {
    /// Default maximum attachment upload size in bytes (20 MB), mirroring `PublicAppConfig.maxAttachmentBytes`.
    public static let defaultMaxAttachmentBytes = 20_000_000

    #if canImport(UniformTypeIdentifiers)
    /// Detects the most accurate MIME type and file extension from raw data and optional source content types.
    ///
    /// Evaluates magic bytes first to match actual file contents, then falls back to `contentTypes`
    /// conforming to `UTType.image`, and defaults to JPEG if unspecified.
    ///
    /// - Parameters:
    ///   - data: The raw image bytes.
    ///   - contentTypes: Supported content types provided by the photo picker item.
    /// - Returns: A tuple containing the MIME type and file extension.
    public static func detectImageFormat(
        from data: Data,
        contentTypes: [UTType] = []
    ) -> (mimeType: String, fileExtension: String) {
        if let sniffed = sniffImageFormat(from: data) {
            return sniffed
        }

        for type in contentTypes where type.conforms(to: .image) {
            let mime = type.preferredMIMEType ?? "image/jpeg"
            let ext = type.preferredFilenameExtension ?? "jpg"
            return (mime, ext)
        }

        return ("image/jpeg", "jpg")
    }
    #else
    /// Detects the most accurate MIME type and file extension from raw data.
    ///
    /// - Parameter data: The raw image bytes.
    /// - Returns: A tuple containing the MIME type and file extension.
    public static func detectImageFormat(
        from data: Data
    ) -> (mimeType: String, fileExtension: String) {
        if let sniffed = sniffImageFormat(from: data) {
            return sniffed
        }
        return ("image/jpeg", "jpg")
    }
    #endif

    /// Sniffs common image format magic headers from raw bytes.
    ///
    /// Supports PNG, JPEG, GIF, WebP, and HEIC/HEIF containers.
    /// - Parameter data: The raw bytes to inspect.
    /// - Returns: A tuple with the detected MIME type and extension, or `nil` if unrecognized.
    public static func sniffImageFormat(from data: Data) -> (mimeType: String, fileExtension: String)? {
        if data.count >= 8 {
            let bytes = [UInt8](data.prefix(12))

            // PNG: 89 50 4E 47 0D 0A 1A 0A
            if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
                return ("image/png", "png")
            }

            // JPEG: FF D8 FF
            if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
                return ("image/jpeg", "jpg")
            }

            // GIF: 47 49 46 38 ("GIF8")
            if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) {
                return ("image/gif", "gif")
            }

            // WebP: RIFF .... WEBP
            if bytes.count >= 12,
               bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
               bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
                return ("image/webp", "webp")
            }

            // HEIC / HEIF / ISO Base Media: offset 4: 'ftyp'
            if bytes.count >= 12,
               bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
                let brand = String(bytes: bytes[8..<12], encoding: .ascii)?.lowercased() ?? ""
                let supportedBrands = ["heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1"]
                if supportedBrands.contains(brand) {
                    return ("image/heic", "heic")
                }
            }
        } else if data.count >= 3 && [UInt8](data.prefix(3)) == [0xFF, 0xD8, 0xFF] {
            return ("image/jpeg", "jpg")
        }

        return nil
    }

    /// Generates a collision-resistant filename incorporating a unique UUID.
    ///
    /// - Parameters:
    ///   - fileExtension: The target file extension without a leading dot.
    ///   - id: The unique identifier for the attachment.
    /// - Returns: A filename string formatted as `"screenshot_<uuid>.<ext>"`.
    public static func makeFilename(fileExtension: String, id: UUID = UUID()) -> String {
        "screenshot_\(id.uuidString.lowercased()).\(fileExtension)"
    }

    /// Validates that raw data size does not exceed the allowed byte budget.
    ///
    /// - Parameters:
    ///   - size: Size in bytes of the file.
    ///   - limit: Maximum allowed size in bytes.
    /// - Throws: ``AttachmentValidationError/oversized(size:limit:)`` if `size > limit`.
    public static func validateAttachmentSize(_ size: Int, limit: Int) throws {
        guard size <= limit else {
            throw AttachmentValidationError.oversized(size: size, limit: limit)
        }
    }

    /// Detects SVG markup by signature, since SVG has no single magic number.
    ///
    /// The upload API rejects SVG outright (`415`) because browsers execute
    /// script in it; this lets the SDK reject it locally with a clear message
    /// instead of paying a round trip.
    /// - Parameter data: The raw bytes to inspect.
    /// - Returns: `true` when the bytes look like SVG markup.
    public static func looksLikeSVG(_ data: Data) -> Bool {
        // Skip a UTF-8 BOM and leading whitespace before the first markup byte.
        var start = data.startIndex
        if data.count >= 3, data[start] == 0xEF, data[start + 1] == 0xBB, data[start + 2] == 0xBF {
            start += 3
        }
        while start < data.endIndex, data[start] == 0x20 || data[start] == 0x09 || data[start] == 0x0A || data[start] == 0x0D {
            start += 1
        }
        let prefix = data[start...].prefix(256)
        guard let head = String(bytes: prefix, encoding: .utf8)?.lowercased() else {
            return false
        }
        return head.hasPrefix("<svg") || head.hasPrefix("<?xml")
    }

    /// Whether the upload API cannot accept these bytes directly and they
    /// should be transcoded to JPEG first (`#41` media policy): the server
    /// verifies magic bytes and accepts PNG, JPEG, WebP, and GIF only, so
    /// HEIC/HEIF photos and unrecognized containers need conversion.
    /// - Parameter data: The raw image bytes.
    /// - Returns: `true` when a JPEG transcode is required.
    public static func requiresJPEGTranscode(_ data: Data) -> Bool {
        guard let sniffed = sniffImageFormat(from: data) else {
            return true
        }
        return sniffed.mimeType == "image/heic"
    }

    /// Re-encodes image bytes as JPEG, for sources the upload API does not
    /// accept directly (HEIC/HEIF photos, unrecognized containers).
    ///
    /// Visual orientation is preserved by applying the source's orientation
    /// transform to the decoded pixel buffer. The fresh encode also drops any
    /// embedded metadata, so this doubles as a sanitizer for transcoded paths.
    ///
    /// - Parameter data: The raw image bytes.
    /// - Returns: JPEG bytes, or `nil` when the data cannot be decoded as an image.
    public static func jpegRepresentationResampled(from data: Data) -> Data? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let outputData = NSMutableData()
        #if canImport(UniformTypeIdentifiers)
        let jpegType = UTType.jpeg.identifier as CFString
        #else
        let jpegType = "public.jpeg" as CFString
        #endif
        guard let destination = CGImageDestinationCreateWithData(outputData as CFMutableData, jpegType, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return outputData as Data
    }

    /// Re-encodes image data to strip sensitive metadata (EXIF, GPS location, device serials, TIFF, IPTC),
    /// while preserving image pixels, visual orientation, and container format compatibility.
    ///
    /// Multi-frame animated images (such as animated GIF or animated WebP) are never flattened:
    /// their container-level metadata (WebP `EXIF`/`XMP ` RIFF chunks, GIF EXIF/XMP application
    /// extensions and comment blocks — invisible to ImageIO's property API) is removed at the
    /// byte level instead, so every animation frame and its timing survives intact. Containers
    /// that carry no such metadata pass through byte-identical; containers whose structure
    /// cannot be safely parsed fall back to a single-frame re-encode, so unverified bytes are
    /// never returned (SEC-10).
    ///
    /// - Parameter data: The raw image data.
    /// - Returns: Sanitized image bytes, or `nil` if the data is corrupt or cannot be decoded.
    public static func strippingSensitiveMetadata(from data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }

        // Multi-frame animated inputs (e.g. animated GIF, animated WebP):
        // ImageIO exposes no EXIF/GPS/IPTC dictionaries on their frames, but
        // the container bytes can still carry EXIF/XMP chunks the property
        // API never surfaces (SEC-10). Strip those chunks in place so frames
        // and timing stay intact (#85); nil means the container could not be
        // sanitized safely and falls through to the re-encode below.
        let frameCount = CGImageSourceGetCount(source)
        if frameCount > 1 && isAnimatedImageContainer(source: source, data: data),
           let sanitized = sanitizedAnimatedContainerBytes(for: data, sourceFrameCount: frameCount) {
            return sanitized
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let targetType = targetContainerType(for: source, data: data, image: image)
        let outputData = NSMutableData()
        guard let destination = makeImageDestination(for: outputData, targetType: targetType, image: image) else {
            return nil
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return outputData as Data
    }

    static func isAnimatedImageContainer(source: CGImageSource, data: Data) -> Bool {
        if let type = CGImageSourceGetType(source) as String? {
            #if canImport(UniformTypeIdentifiers)
            if let utType = UTType(type), utType.conforms(to: .gif) || utType.conforms(to: .webP) { return true }
            #else
            if type == "com.compuserve.gif" || type == "org.webmproject.webp" { return true }
            #endif
        }
        if let sniffed = sniffImageFormat(from: data) {
            return sniffed.mimeType == "image/gif" || sniffed.mimeType == "image/webp"
        }
        return false
    }

    private static func targetContainerType(for source: CGImageSource, data: Data, image: CGImage) -> CFString {
        let supportedTypes = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        let hasAlpha = imageHasAlpha(image)

        if let inputType = CGImageSourceGetType(source) as String?, supportedTypes.contains(inputType) {
            return inputType as CFString
        }

        if let sniffed = sniffImageFormat(from: data) {
            if sniffed.mimeType == "image/png" && supportedTypes.contains("public.png") {
                return "public.png" as CFString
            }
            if sniffed.mimeType == "image/heic" && supportedTypes.contains("public.heic") {
                return "public.heic" as CFString
            }
        }

        return (hasAlpha && supportedTypes.contains("public.png")) ? ("public.png" as CFString) : ("public.jpeg" as CFString)
    }

    private static func makeImageDestination(
        for outputData: NSMutableData,
        targetType: CFString,
        image: CGImage
    ) -> CGImageDestination? {
        if let destination = CGImageDestinationCreateWithData(outputData as CFMutableData, targetType, 1, nil) {
            return destination
        }
        let fallbackType = imageHasAlpha(image) ? ("public.png" as CFString) : ("public.jpeg" as CFString)
        return CGImageDestinationCreateWithData(outputData as CFMutableData, fallbackType, 1, nil)
    }

    private static func imageHasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            return true
        default:
            return false
        }
    }
}
