import Foundation
import Testing
@testable import CupThreadFeedback

/// Guards the DocC guides against drifting from the shipped API.
///
/// DocC catalogs are documentation assets, not bundled resources, so the
/// catalog is located by walking up from this source file to the package root.
@Suite("DocC content")
struct DocCContentTests {
    private func doccCatalog() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            directory.deleteLastPathComponent()
            let candidate = directory
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CupThreadFeedback", isDirectory: true)
                .appendingPathComponent("CupThreadFeedback.docc", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        try #require(
            false,
            "Could not locate Sources/CupThreadFeedback/CupThreadFeedback.docc by walking up from \(#filePath)"
        )
        return URL(fileURLWithPath: #filePath) // unreachable; #require throws first
    }

    private func readMarkdown(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @Test func doccGuidesDoNotReferencePhantomIdentifiers() throws {
        let phantomIdentifiers = [
            "customMetadata",   // FeedbackDraft field is `metadata`
            "config.appearance", // PublicAppConfig field is `sdk`
            "Emerald",          // never an SdkTheme case
            "Lavender"          // never an SdkTheme case
        ]

        let catalog = try doccCatalog()
        let files = try FileManager.default
            .contentsOfDirectory(at: catalog, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
        try #require(!files.isEmpty, "No markdown guides found in \(catalog.path)")

        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let content = try readMarkdown(file)
            for identifier in phantomIdentifiers {
                #expect(
                    !content.contains(identifier),
                    "\(file.lastPathComponent) references phantom identifier '\(identifier)' — the guide drifted from the shipped API"
                )
            }
        }
    }

    @Test func themePresetsSectionMatchesSdkThemeCases() throws {
        let file = try doccCatalog().appendingPathComponent("CustomizingAppearance.md")
        let content = try readMarkdown(file)

        let sectionStart = try #require(
            content.range(of: "## Theme presets"),
            "CustomizingAppearance.md lost its 'Theme presets' section"
        )
        let remainder = content[sectionStart.upperBound...]
        let sectionLines = remainder.split(separator: "\n", omittingEmptySubsequences: false)
        var documentedNames = Set<String>()
        for line in sectionLines {
            if line.hasPrefix("## ") { break } // next section begins
            guard line.hasPrefix("- **"),
                  let nameEnd = line.dropFirst(4).range(of: "**")
            else { continue }
            documentedNames.insert(String(line.dropFirst(4)[..<nameEnd.lowerBound]))
        }

        let actualNames = Set(SdkTheme.allCases.map(\.label))
        #expect(
            documentedNames == actualNames,
            "Theme list in CustomizingAppearance.md (\(documentedNames.sorted())) does not match SdkTheme.allCases (\(actualNames.sorted())) — a preset was renamed, added, or removed without updating the guide"
        )
    }
}
