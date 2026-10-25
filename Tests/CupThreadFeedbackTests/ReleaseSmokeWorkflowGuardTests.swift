import Foundation
import Testing

// Repository-level contract for the `Release Smoke Test` workflow (issue
// #586). The workflow exists to prove that one specific published version
// resolves for consumers, so the manifests it generates must pin that version
// exactly. SwiftPM resolves a `from:` range to the newest tag below the next
// major — never the requested one — so a range requirement makes a manual
// dispatch for a past release build a different version and then fail the
// sdkVersion check against the version it never resolved (a false release
// incident), or green-check a version nobody asked for. The consumer-facing
// README keeps its `from:` snippet: the range is right for consumers, and only
// the verification harness must pin.
@Suite("Release smoke workflow guard")
struct ReleaseSmokeWorkflowGuardTests {
    private enum ContractError: Error {
        case repositoryRootNotFound
        case stepNotFound(String)
    }

    private static let sourceStep = "Source package resolves from the published tag"
    private static let binaryStep = "Binary target imports the published CDN artifact"

    private let workflowText: String

    init() throws {
        var url = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            guard url.pathComponents.count > 1 else {
                throw ContractError.repositoryRootNotFound
            }
            url.deleteLastPathComponent()
        }
        workflowText = try String(
            contentsOf: url.appendingPathComponent(".github/workflows/release-smoke.yml"),
            encoding: .utf8
        )
    }

    /// One named step, sliced from its `name:` line up to the next step, so an
    /// assertion cannot be satisfied by text that lives in a neighbouring step.
    private func step(named name: String) throws -> String {
        guard let start = workflowText.range(of: "- name: \(name)") else {
            throw ContractError.stepNotFound(name)
        }
        let rest = workflowText[start.upperBound...]
        let end = rest.range(of: "\n      - name: ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    @Test func sourcePackageStepPinsTheRequestedVersionExactly() throws {
        let source = try step(named: Self.sourceStep)
        let requirements = source
            .matches(of: /\.package\(url: "https:\/\/github\.com\/CupThread\/CupThreadSwiftSDK\.git",\s*([^)]*)\)/)
            .map { String($0.1) }
        #expect(
            requirements == [#"exact: "$VERSION""#],
            "the smoke manifest must pin the release under test with exact: \"$VERSION\"; got \(requirements)"
        )
    }

    @Test func sourcePackageStepChecksTheResolvedVersionBeforeBuilding() throws {
        let source = try step(named: Self.sourceStep)
        let resolvedCheck = try #require(source.range(of: "swift package show-dependencies"))
        let build = try #require(source.range(of: "swift build"))
        #expect(
            resolvedCheck.lowerBound < build.lowerBound,
            "the resolved version must be compared with the requested one before the build so a mismatch fails fast"
        )
        #expect(source.contains(#"[ "$RESOLVED" != "$VERSION" ]"#))
    }

    @Test func binaryTargetStepPinsTheRequestedArtifactAndChecksum() throws {
        let binary = try step(named: Self.binaryStep)
        #expect(binary.contains(#"url: "https://cdn.cupthread.com/sdks/apple/CupThreadFeedback-$VERSION.xcframework.zip""#))
        #expect(binary.contains(#"checksum: "$CHECKSUM""#))
    }
}
