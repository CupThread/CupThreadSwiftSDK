import Foundation
import Testing
@testable import CupThreadFeedback

/// Guards the screenshot gallery invariant: the DocC catalog commits
/// exactly the six canonical JPEG showcase screenshots — no PNG duplicates,
/// no stray or empty image files. Mirrors the shell-level check in
/// `scripts/verify-screenshots.sh` so `swift test` fails on any drift.
@Suite("Screenshot assets")
struct ScreenshotAssetTests {
    private let canonicalNames = [
        "changelog_overlay",
        "feature_requests",
        "feedback_composer",
        "roadmap",
        "submit_request",
        "whats_new"
    ]

    private func doccResources() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            directory.deleteLastPathComponent()
            let candidate = directory
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CupThreadFeedback", isDirectory: true)
                .appendingPathComponent("CupThreadFeedback.docc", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        try #require(
            false,
            "Could not locate Sources/CupThreadFeedback/CupThreadFeedback.docc/Resources by walking up from \(#filePath)"
        )
        return URL(fileURLWithPath: #filePath) // unreachable; #require throws first
    }

    private func imageFiles() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: doccResources(), includingPropertiesForKeys: [.fileSizeKey])
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test func galleryShipsOnlyJpegScreenshots() throws {
        let nonJpeg = try imageFiles().filter { $0.pathExtension.lowercased() != "jpg" }
        #expect(
            nonJpeg.isEmpty,
            "Non-JPEG screenshot assets committed: \(nonJpeg.map(\.lastPathComponent)) — run scripts/capture-screenshots.sh and commit only the canonical .jpg set"
        )
    }

    @Test func galleryContainsNoStrayImages() throws {
        let canonical = Set(canonicalNames.map { "\($0).jpg" })
        let strays = try imageFiles().map(\.lastPathComponent).filter { !canonical.contains($0) }
        #expect(
            strays.isEmpty,
            "Unexpected image files in DocC Resources: \(strays) — the gallery must contain only the six canonical .jpg screenshots"
        )
    }

    @Test func allCanonicalScreenshotsArePresentAndNonEmpty() throws {
        let present = Set(try imageFiles().map(\.lastPathComponent))
        let resources = try doccResources()
        for name in canonicalNames {
            let fileName = "\(name).jpg"
            #expect(
                present.contains(fileName),
                "Canonical screenshot missing: \(fileName)"
            )
            if present.contains(fileName) {
                let path = resources.appendingPathComponent(fileName).path
                let size = (try FileManager.default.attributesOfItem(atPath: path))[.size] as? Int
                #expect(
                    (size ?? 0) > 0,
                    "Canonical screenshot is empty: \(fileName)"
                )
            }
        }
    }
}
