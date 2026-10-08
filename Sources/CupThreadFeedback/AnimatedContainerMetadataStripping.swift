import Foundation
import ImageIO

/// Outcome of attempting byte-level metadata surgery on an animated
/// (multi-frame) GIF or WebP container (SEC-10).
enum AnimatedContainerSanitizationOutcome: Equatable {
    /// The container carries no EXIF/XMP/comment payload: the original bytes
    /// are already sanitized and can pass through byte-identical.
    case clean
    /// Metadata chunks were surgically removed; the rewritten container
    /// preserves every animation frame and its timing bit-for-bit.
    case sanitized(Data)
    /// The container structure cannot be parsed safely. Callers must not
    /// pass the original bytes through and should fall back to a re-encode.
    case unsafe
}

extension PhotoAttachmentHelper {
    /// Applies SEC-10 metadata stripping to an animated container's bytes.
    ///
    /// ImageIO's property API exposes no EXIF/GPS/IPTC dictionaries on GIF or
    /// animated WebP frames, but the container bytes themselves can carry
    /// metadata the property API never surfaces: WebP defines top-level RIFF
    /// `EXIF`/`XMP ` chunks, GIF defines EXIF/XMP application extensions plus
    /// free-text comment extensions. Clean containers come back unchanged,
    /// metadata-bearing containers come back with those chunks surgically
    /// removed, and containers that cannot be parsed safely come back as
    /// `nil` so the caller falls back to a single-frame re-encode instead of
    /// ever passing the original bytes through.
    ///
    /// - Parameters:
    ///   - data: The raw animated container bytes.
    ///   - sourceFrameCount: Frame count ImageIO reported for `data`, used to
    ///     verify the rewritten container still parses.
    static func sanitizedAnimatedContainerBytes(for data: Data, sourceFrameCount: Int) -> Data? {
        switch stripAnimatedContainerMetadata(from: data) {
        case .clean:
            // No metadata chunks in the container: the original bytes are
            // already sanitized, preserve them bit-for-bit.
            return data
        case .sanitized(let sanitized):
            // Chunk surgery rewrites container metadata only; verify the
            // rewritten container still parses with the same frame count
            // before trusting it.
            return verifiesFrameCount(of: sanitized, expected: sourceFrameCount) ? sanitized : nil
        case .unsafe:
            return nil
        }
    }

    /// Detects and strips container-level metadata from an animated GIF or
    /// WebP payload.
    static func stripAnimatedContainerMetadata(from data: Data) -> AnimatedContainerSanitizationOutcome {
        switch sniffImageFormat(from: data)?.mimeType {
        case "image/webp":
            return stripWebPContainerMetadata(from: data)
        case "image/gif":
            return stripGIFContainerMetadata(from: data)
        default:
            return .unsafe
        }
    }

    // MARK: - WebP (RIFF container)

    /// Removes top-level `EXIF` and `XMP ` RIFF chunks from a WebP container,
    /// rewriting chunk offsets, the container size, and the matching `VP8X`
    /// flag bits. Every other chunk (`VP8X`, `ANIM`, `ANMF`, `ALPH`, `VP8`,
    /// `VP8L`, `ICCP`) is copied verbatim, so animation frames and timing
    /// survive unchanged.
    static func stripWebPContainerMetadata(from data: Data) -> AnimatedContainerSanitizationOutcome {
        let bytes = [UInt8](data)
        guard hasWebPHeader(bytes),
              let chunks = webPChunkRanges(in: bytes, riffEnd: riffContentEnd(bytes: bytes)) else {
            return .unsafe
        }
        guard chunks.contains(where: { isMetadataChunk(fourCC(at: $0.lowerBound, in: bytes)) }) else {
            return .clean
        }
        return .sanitized(rewrittenWebP(bytes: bytes, keeping: chunks))
    }

    /// Whether `bytes` starts with a RIFF header advertising the WebP form.
    private static func hasWebPHeader(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 12
            && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 // "RIFF"
            && bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50 // "WEBP"
    }

    private static func riffContentEnd(bytes: [UInt8]) -> Int {
        min(8 + Int(le32(bytes, at: 4)), bytes.count)
    }

    /// Ranges of every top-level RIFF chunk (including its pad byte), or nil
    /// when a chunk size overruns the container.
    private static func webPChunkRanges(in bytes: [UInt8], riffEnd: Int) -> [Range<Int>]? {
        var ranges: [Range<Int>] = []
        var offset = 12
        while offset + 8 <= riffEnd {
            let size = Int(le32(bytes, at: offset + 4))
            let payloadEnd = offset + 8 + size
            guard payloadEnd <= riffEnd else { return nil }
            ranges.append(offset..<min(payloadEnd + (size & 1), bytes.count)) // odd chunks carry a pad byte
            offset = payloadEnd + (size & 1)
        }
        return ranges.isEmpty ? nil : ranges
    }

    /// Copies every chunk except `EXIF`/`XMP ` into a fresh container,
    /// clearing the `VP8X` EXIF/XMP flag bits and patching the RIFF size.
    private static func rewrittenWebP(bytes: [UInt8], keeping chunks: [Range<Int>]) -> Data {
        var output = [UInt8]()
        output.reserveCapacity(bytes.count)
        output.append(contentsOf: bytes[0..<12]) // RIFF header, size patched below
        for range in chunks where !isMetadataChunk(fourCC(at: range.lowerBound, in: bytes)) {
            let outputChunkStart = output.count
            output.append(contentsOf: bytes[range])
            if fourCC(at: range.lowerBound, in: bytes) == webPVP8XFourCC, bytes[range.lowerBound + 4] >= 1 {
                // Clear the EXIF (0x08) and XMP (0x04) presence flags of the
                // chunks removed above.
                output[outputChunkStart + 8] &= ~0x0C
            }
        }
        writeLE32(UInt32(output.count - 8), into: &output, at: 4)
        return Data(output)
    }

    private static func isMetadataChunk(_ code: [UInt8]) -> Bool {
        code == webPEXIFFourCC || code == webPXMPFourCC
    }

    private static let webPEXIFFourCC: [UInt8] = [0x45, 0x58, 0x49, 0x46] // "EXIF"
    private static let webPXMPFourCC: [UInt8] = [0x58, 0x4D, 0x50, 0x20] // "XMP "
    private static let webPVP8XFourCC: [UInt8] = [0x56, 0x50, 0x38, 0x58]

    private static func fourCC(at offset: Int, in bytes: [UInt8]) -> [UInt8] {
        Array(bytes[offset..<offset + 4])
    }

    // MARK: - GIF

    /// Removes metadata extension blocks from a GIF container: the EXIF
    /// application extension, the `XMP DataXMP` application extension, and
    /// comment extensions (free text that routinely carries author or tool
    /// info). Graphic control and plain text extensions, loop-configuring
    /// application extensions (`NETSCAPE2.0`, `ANIMEXTS1.0`), and every
    /// image block are kept byte-for-byte, so frame count, delays, and
    /// looping are unchanged.
    static func stripGIFContainerMetadata(from data: Data) -> AnimatedContainerSanitizationOutcome {
        let bytes = [UInt8](data)
        guard hasGIFHeader(bytes), let blocks = gifBlocks(in: bytes) else { return .unsafe }
        // The walk must end at the trailer for the container to count as
        // structurally complete; anything else falls back to a re-encode.
        guard let trailer = blocks.last, bytes[trailer.range.lowerBound] == 0x3B else { return .unsafe }
        let dropRanges = blocks.filter(\.isMetadata).map(\.range)
        guard !dropRanges.isEmpty else { return .clean }
        return .sanitized(Data(splicing(bytes, removing: dropRanges)))
    }

    /// One walked GIF block: the byte range it occupies and whether it is a
    /// metadata extension that must be dropped.
    private struct GIFBlock {
        var range: Range<Int>
        var isMetadata: Bool
    }

    private static func hasGIFHeader(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 6
            && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38 // "GIF8"
    }

    /// Walks every block in the GIF block stream in order, or returns nil
    /// when the structure is malformed (unknown introducer, truncation).
    private static func gifBlocks(in bytes: [UInt8]) -> [GIFBlock]? {
        guard var offset = gifFirstBlockOffset(bytes: bytes) else { return nil }
        var blocks: [GIFBlock] = []
        while offset < bytes.count {
            switch bytes[offset] {
            case 0x21: // extension introducer
                guard let (range, isMetadata) = gifExtensionRange(at: offset, in: bytes) else { return nil }
                blocks.append(GIFBlock(range: range, isMetadata: isMetadata))
                offset = range.upperBound
            case 0x2C: // image descriptor
                guard let end = gifImageBlockEnd(at: offset, in: bytes) else { return nil }
                blocks.append(GIFBlock(range: offset..<end, isMetadata: false))
                offset = end
            case 0x3B: // trailer
                blocks.append(GIFBlock(range: offset..<bytes.count, isMetadata: false))
                offset = bytes.count
            default:
                return nil
            }
        }
        return blocks
    }

    /// Offset of the first block after the header, logical screen
    /// descriptor, and optional global color table.
    private static func gifFirstBlockOffset(bytes: [UInt8]) -> Int? {
        guard bytes.count >= 14 else { return nil }
        var offset = 13 // header + logical screen descriptor
        let packed = bytes[10]
        if packed & 0x80 != 0 { // global color table follows
            offset += 3 * (1 << (Int(packed & 0x07) + 1))
        }
        return offset <= bytes.count ? offset : nil
    }

    /// Parses the extension block starting at `offset` (introducer already
    /// verified), returning its byte range and whether it is a metadata
    /// extension, or nil when its sub-blocks are truncated.
    private static func gifExtensionRange(
        at offset: Int,
        in bytes: [UInt8]
    ) -> (range: Range<Int>, isMetadata: Bool)? {
        guard offset + 2 <= bytes.count else { return nil }
        let label = bytes[offset + 1]
        guard let (end, firstSubBlock) = gifSubBlocks(from: offset + 2, in: bytes) else { return nil }
        let isMetadata = label == 0xFE // comment: free text, routinely author/tool info
            || (label == 0xFF && isMetadataApplicationIdentifier(firstSubBlock))
        return (offset..<end, isMetadata)
    }

    /// Parses the image block starting at `offset` (image descriptor, local
    /// color table, LZW data sub-blocks), returning the offset just past it,
    /// or nil when truncated.
    private static func gifImageBlockEnd(at offset: Int, in bytes: [UInt8]) -> Int? {
        guard offset + 10 <= bytes.count else { return nil }
        let packed = bytes[offset + 9]
        var cursor = offset + 10
        if packed & 0x80 != 0 { // local color table follows
            cursor += 3 * (1 << (Int(packed & 0x07) + 1))
            guard cursor <= bytes.count else { return nil }
        }
        guard cursor < bytes.count else { return nil }
        cursor += 1 // LZW minimum code size byte
        return gifSubBlocks(from: cursor, in: bytes)?.end
    }

    /// Walks GIF data sub-blocks starting at `offset` (length-prefixed,
    /// terminated by a zero length), returning the offset just past the
    /// terminator plus the contents of the first sub-block, or nil when
    /// truncated.
    private static func gifSubBlocks(from offset: Int, in bytes: [UInt8]) -> (end: Int, firstSubBlock: [UInt8])? {
        var cursor = offset
        var firstSubBlock: [UInt8] = []
        var subBlockIndex = 0
        while true {
            guard cursor < bytes.count else { return nil }
            let length = Int(bytes[cursor])
            cursor += 1
            if length == 0 { return (cursor, firstSubBlock) }
            guard cursor + length <= bytes.count else { return nil }
            if subBlockIndex == 0 {
                firstSubBlock = Array(bytes[cursor..<cursor + length])
            }
            cursor += length
            subBlockIndex += 1
        }
    }

    private static func splicing(_ bytes: [UInt8], removing ranges: [Range<Int>]) -> [UInt8] {
        var output = [UInt8]()
        output.reserveCapacity(bytes.count)
        var cursor = 0
        for range in ranges {
            output.append(contentsOf: bytes[cursor..<range.lowerBound])
            cursor = range.upperBound
        }
        output.append(contentsOf: bytes[cursor...])
        return output
    }

    /// Whether an 11-byte GIF application extension identifier names a
    /// metadata carrier: the EXIF embedding (identifier starting `Exif`,
    /// per the Exif-in-GIF specification) or the Adobe XMP embedding
    /// (`XMP DataXMP`). Loop control (`NETSCAPE2.0`, `ANIMEXTS1.0`) and
    /// other application extensions do not match.
    static func isMetadataApplicationIdentifier(_ identifier: [UInt8]) -> Bool {
        guard identifier.count >= 11 else { return false }
        let prefix = identifier.prefix(4).map { byte in
            byte >= 0x61 && byte <= 0x7A ? byte &- 0x20 : byte // ASCII case fold
        }
        return prefix == [0x45, 0x58, 0x49, 0x46] // "EXIF"
            || prefix == [0x58, 0x4D, 0x50, 0x20] // "XMP "
    }

    /// Whether `data` still parses as an image container with exactly the
    /// expected frame count. A cheap ImageIO re-read of the container
    /// structure (no pixel decode) guarding the byte surgery above before
    /// its result is trusted.
    static func verifiesFrameCount(of data: Data, expected: Int) -> Bool {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return false
        }
        return CGImageSourceGetCount(source) == expected
    }

    private static func le32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func writeLE32(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
