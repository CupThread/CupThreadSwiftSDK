import Foundation

// MARK: - Public Image Thumbnail Width

/// Documented square thumbnail width hints supported by the CupThread public image
/// delivery endpoint (`GET /api/v1/files/{key}?width=...`).
///
/// The public image delivery contract accepts only this fixed size set:
/// `16`, `32`, `36`, `56`, `64`, `72`, `80`, `112`, `128`, or `160`.
/// Width-hint responses carry a five-minute cache lifetime and may return
/// a WebP thumbnail or the original image bytes.
public enum PublicImageThumbnailWidth: Int, Sendable, CaseIterable {
    case width16 = 16
    case width32 = 32
    case width36 = 36
    case width56 = 56
    case width64 = 64
    case width72 = 72
    case width80 = 80
    case width112 = 112
    case width128 = 128
    case width160 = 160

    // Convenience shorthand aliases matching common token sizes
    public static let w16: Self = .width16
    public static let w32: Self = .width32
    public static let w36: Self = .width36
    public static let w56: Self = .width56
    public static let w64: Self = .width64
    public static let w72: Self = .width72
    public static let w80: Self = .width80
    public static let w112: Self = .width112
    public static let w128: Self = .width128
    public static let w160: Self = .width160

    /// The set of all documented thumbnail width integer values.
    public static let allowedWidths: Set<Int> = Set(allCases.map(\.rawValue))
}

// MARK: - Public Image Delivery Helpers

/// Applies an optional documented thumbnail width hint to a public image URL,
/// preserving path and query string as an opaque URL, and preserving original-image
/// fallback when `width` is `nil` or URL components cannot be constructed.
///
/// - Parameters:
///   - url: The source image URL (typically pointing to `https://api.cupthread.com/api/v1/files/{key}`).
///   - width: The documented thumbnail width to request. If `nil`, the original
///     URL is returned unchanged (original-image fallback).
/// - Returns: The URL with the `width` query parameter appended or updated, or
///   the original `url` if `width` is `nil` or URL components cannot be constructed.
public func publicImageThumbnailURL(for url: URL, width: PublicImageThumbnailWidth?) -> URL {
    guard let width else { return url }
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return url
    }
    var queryItems = components.queryItems ?? []
    queryItems.removeAll { $0.name == "width" }
    queryItems.append(URLQueryItem(name: "width", value: String(width.rawValue)))
    components.queryItems = queryItems
    return components.url ?? url
}

/// Applies an integer thumbnail width hint to a public image URL, preserving
/// original-image fallback for unsupported width values.
///
/// Only documented width values (16, 32, 36, 56, 64, 72, 80, 112, 128, 160)
/// are applied as query hints; any other value returns the original `url`
/// unmodified (original-image fallback).
///
/// - Parameters:
///   - url: The source image URL.
///   - width: The raw integer thumbnail width hint.
/// - Returns: The URL with the `width` query parameter if `width` is a documented
///   size, or `url` unchanged.
public func publicImageThumbnailURL(for url: URL, width: Int?) -> URL {
    guard let width, let thumbnailWidth = PublicImageThumbnailWidth(rawValue: width) else {
        return url
    }
    return publicImageThumbnailURL(for: url, width: thumbnailWidth)
}

/// Parses an untrusted remote image URL string and applies an optional documented
/// thumbnail width hint, validating against the secure image policy and preserving
/// original-image fallback.
///
/// - Parameters:
///   - string: The candidate image URL string.
///   - width: The documented thumbnail width hint.
/// - Returns: A valid secure `URL` with the thumbnail hint applied, the original
///   secure `URL` if `width` is `nil`, or `nil` if the string violates URL policy.
public func publicImageThumbnailURL(from string: String?, width: PublicImageThumbnailWidth? = nil) -> URL? {
    guard let url = remoteImageURL(from: string) else { return nil }
    guard let width else { return url }
    return publicImageThumbnailURL(for: url, width: width)
}

/// Parses an untrusted remote image URL string and applies an optional integer
/// thumbnail width hint, validating against the secure image policy and preserving
/// original-image fallback for unsupported width values.
///
/// - Parameters:
///   - string: The candidate image URL string.
///   - width: The raw integer thumbnail width hint.
/// - Returns: A valid secure `URL` with the thumbnail hint applied, the original
///   secure `URL` if `width` is unsupported or `nil`, or `nil` if the string violates URL policy.
public func publicImageThumbnailURL(from string: String?, width: Int?) -> URL? {
    guard let url = remoteImageURL(from: string) else { return nil }
    guard let width, let thumbnailWidth = PublicImageThumbnailWidth(rawValue: width) else {
        return url
    }
    return publicImageThumbnailURL(for: url, width: thumbnailWidth)
}

// MARK: - URL Extension

extension URL {
    /// Returns a copy of this URL with a documented thumbnail width hint applied,
    /// or `self` if `width` is `nil` or URL components cannot be constructed.
    public func appendingThumbnailWidth(_ width: PublicImageThumbnailWidth?) -> URL {
        publicImageThumbnailURL(for: self, width: width)
    }

    /// Returns a copy of this URL with an integer thumbnail width hint applied,
    /// preserving original-image fallback for unsupported width values.
    public func appendingThumbnailWidth(_ width: Int?) -> URL {
        publicImageThumbnailURL(for: self, width: width)
    }
}
