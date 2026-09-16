import Foundation
import ImageIO
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

extension PhotoAttachmentHelper {
    /// A photo normalized for the upload API: final bytes plus the MIME type
    /// and file extension detected from those bytes.
    struct PreparedPhoto: Sendable {
        /// The upload-ready image bytes.
        let data: Data
        /// MIME type of `data` (for example `image/jpeg`).
        let mimeType: String
        /// File extension for `data` without a leading dot (for example `jpg`).
        let fileExtension: String
    }

    /// Re-encodes image bytes as a downscaled JPEG that fits within `limit`.
    ///
    /// The bitmap is decoded with its longest edge capped at `maxDimension`
    /// (orientation-corrected), so an oversized panorama or ProRAW shot never
    /// materializes at full resolution. The JPEG encode quality steps down
    /// from 0.8 (through 0.6 and 0.4) until the output fits. The fresh encode
    /// also drops any embedded EXIF/GPS metadata.
    ///
    /// - Parameters:
    ///   - data: The raw image bytes, typically an oversized photo.
    ///   - limit: Maximum allowed size in bytes for the returned data.
    ///   - maxDimension: Cap for the longest pixel edge of the decoded bitmap.
    /// - Returns: JPEG bytes no larger than `limit`, or `nil` when the data
    ///   cannot be decoded as an image or still exceeds `limit` at the lowest
    ///   quality.
    public static func downscaledImageData(
        _ data: Data,
        limit: Int,
        maxDimension: CGFloat = 4096
    ) -> Data? {
        guard !data.isEmpty, limit > 0,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else {
            return nil
        }
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCache: false
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions as CFDictionary) else {
            return nil
        }
        for quality in [0.8, 0.6, 0.4] {
            guard let encoded = jpegData(from: image, quality: quality) else {
                return nil
            }
            if encoded.count <= limit {
                return encoded
            }
        }
        return nil
    }

    /// Runs the composer-side preparation pipeline over picked photo bytes:
    /// oversized photos are downscaled to fit `limit`, SVG is rejected
    /// locally, sensitive metadata is optionally stripped, HEIC/HEIF and
    /// unrecognized containers are transcoded to JPEG, and the final bytes
    /// are validated against `limit`.
    ///
    /// Under-limit images in formats the upload API accepts as-is pass
    /// through byte-identical when `stripSensitiveMetadata` is `false`.
    ///
    /// - Parameters:
    ///   - data: The raw image bytes from the photo picker.
    ///   - limit: Maximum allowed upload size in bytes.
    ///   - stripSensitiveMetadata: Whether to re-encode and strip EXIF/GPS metadata.
    /// - Returns: The prepared photo ready for upload.
    /// - Throws: ``AttachmentValidationError/unsupportedType`` for SVG or
    ///   undecodable HEIC/HEIF-like containers,
    ///   ``AttachmentValidationError/oversized(size:limit:)`` when no
    ///   downscale can fit the bytes under `limit`, and
    ///   ``AttachmentValidationError/unprocessableImage`` when metadata
    ///   stripping fails.
    static func prepareForUpload(
        _ data: Data,
        limit: Int,
        stripSensitiveMetadata: Bool
    ) throws -> PreparedPhoto {
        var data = data

        if looksLikeSVG(data) {
            throw AttachmentValidationError.unsupportedType
        }

        // Oversized photos get one automatic downscale/re-encode attempt (#52)
        // before the hard size limit turns them away; under-limit bytes are
        // never recompressed here.
        if data.count > limit {
            guard let downscaled = downscaledImageData(data, limit: limit) else {
                throw AttachmentValidationError.oversized(size: data.count, limit: limit)
            }
            data = downscaled
        }

        if stripSensitiveMetadata {
            guard let sanitized = strippingSensitiveMetadata(from: data) else {
                throw AttachmentValidationError.unprocessableImage
            }
            data = sanitized
        }

        // The upload API verifies magic bytes and accepts PNG, JPEG, WebP,
        // and GIF only — transcode HEIC/HEIF (the iPhone photo default) and
        // anything it cannot verify.
        if requiresJPEGTranscode(data) {
            guard let jpeg = jpegRepresentationResampled(from: data) else {
                throw AttachmentValidationError.unsupportedType
            }
            data = jpeg
        }

        try validateAttachmentSize(data.count, limit: limit)

        let format = detectImageFormat(from: data)
        return PreparedPhoto(data: data, mimeType: format.mimeType, fileExtension: format.fileExtension)
    }

    private static func jpegData(from image: CGImage, quality: Double) -> Data? {
        let outputData = NSMutableData()
        #if canImport(UniformTypeIdentifiers)
        let jpegType = UTType.jpeg.identifier as CFString
        #else
        let jpegType = "public.jpeg" as CFString
        #endif
        guard let destination = CGImageDestinationCreateWithData(outputData as CFMutableData, jpegType, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return outputData as Data
    }
}
