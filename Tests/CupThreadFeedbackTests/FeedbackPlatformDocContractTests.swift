import Foundation
import Testing
@testable import CupThreadFeedback

/// Pins the documentation side of the platform-reporting contract for
/// issue #290.
///
/// `FeedbackPlatform` mirrors the backend schema (`ios` / `macos` /
/// `android` / `universal`), so `visionos` and `tvos` are not reportable
/// values: visionOS and tvOS are iOS-family builds, `FeedbackPlatform.current`
/// reports `.ios` there (runtime behavior pinned by `FeedbackPlatformTests.currentMatchesHostPlatform`),
/// and integrators who build a console allow-list from a doc naming
/// `visionos` silently block every submission from those platforms. These
/// tests keep the enum case set and the README/DocC copy from drifting apart.
@Suite("FeedbackPlatformDocContract")
struct FeedbackPlatformDocContractTests {
    @Test func casesMirrorTheBackendSchema() {
        let rawValues = Set(FeedbackPlatform.allCases.map(\.rawValue))
        #expect(
            rawValues == ["ios", "macos", "android", "universal"],
            "FeedbackPlatform case set drifted — update the enum docs, the README platform sentence, and this pin together"
        )    }

    // MARK: Repository-level documentation guards

    private enum ContractError: Error {
        case repositoryRootNotFound
    }

    private func repositoryRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            guard url.pathComponents.count > 1 else {
                throw ContractError.repositoryRootNotFound
            }
            url.deleteLastPathComponent()
        }
        return url
    }

    private func doccCatalog() throws -> URL {
        try repositoryRoot()
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("CupThreadFeedback", isDirectory: true)
            .appendingPathComponent("CupThreadFeedback.docc", isDirectory: true)
    }

    @Test func readmePlatformSentenceOnlyNamesEnumCases() throws {
        let readme = try String(
            contentsOf: repositoryRoot().appendingPathComponent("README.md"),
            encoding: .utf8
        )
        let sentence = try #require(
            readme
                .split(separator: "\n")
                .first { $0.contains("FeedbackPlatform.current") && $0.contains("report") },
            "README lost the sentence documenting what FeedbackPlatform.current reports"
        )

        // Every backticked token in that sentence except the type reference
        // itself must be a real FeedbackPlatform case, so an allow-list built
        // from the README can never name a value the SDK never reports.
        let chunks = sentence.split(separator: "`", omittingEmptySubsequences: false)
        let tokens = chunks.indices.filter { $0 % 2 == 1 }.map { String(chunks[$0]) }
        let platformTokens = tokens.filter { $0 != "FeedbackPlatform.current" }
        try #require(
            !platformTokens.isEmpty,
            "README platform sentence no longer names any platform values"
        )
        let knownCases = Set(FeedbackPlatform.allCases.map(\.rawValue))
        for token in platformTokens {
            #expect(
                knownCases.contains(token),
                "README claims FeedbackPlatform reports '\(token)', which is not a FeedbackPlatform case"
            )
        }
    }

    @Test func guidesNeverPresentVisionOSOrTvOSAsReportableValues() throws {
        let guideFiles = try FileManager.default
            .contentsOfDirectory(at: doccCatalog(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
        let files = [try repositoryRoot().appendingPathComponent("README.md")] + guideFiles
        try #require(files.count > 1, "Expected the README plus at least one DocC guide")

        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let content = try String(contentsOf: file, encoding: .utf8)
            for value in ["`visionos`", "`tvos`"] {
                #expect(
                    !content.contains(value),
                    "\(file.lastPathComponent) presents \(value) as a reportable platform value — visionOS and tvOS are iOS-family builds that report ios"
                )
            }
        }
    }
}
