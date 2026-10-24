import Foundation
import Testing

/// The docs/tag drift guard (#553): the README's install instructions and the
/// repository's published tags must never drift apart. Every version the README
/// tells consumers to install — the SPM `from:` requirement and the binary
/// target's pinned artifact — has to resolve against the `v*` tags that actually
/// exist on origin. A `from:` requirement resolves to the greatest tag inside
/// `[X.Y.Z, (X+1).0.0)` — SwiftPM excludes the next major from the range — so
/// at least one tag must exist inside that window; the binary target pins an
/// exact version, so its tag must exist verbatim. #553 found the opposite
/// state: `from: "0.1.0"` had never been installable because the repository
/// had no tags at all, every consumer's `swift package resolve` failed, and
/// nothing in CI noticed.
///
/// Like ``ReleasePreflightTests``, the version arithmetic is driven through the
/// pure helpers exported from `scripts/release.mjs` (`greatestVersionTag`,
/// `compareSemver`, `isSemver`), so the README is judged by exactly the rules
/// the release pipeline enforces.
@Suite("Release README guard")
struct ReleaseReadmeGuardTests {
    private struct Verdict: Decodable {
        let greatest: String?
        let problems: [String]
    }

    @Test func readmeInstallRequirementsResolveAgainstPublishedTags() throws {
        let readme = try String(
            contentsOf: Self.repoRoot().appendingPathComponent("README.md"),
            encoding: .utf8
        )
        let fromRequirements = Self.readmeFromRequirements(readme)
        let pinnedArtifacts = Self.readmePinnedArtifactVersions(readme)
        #expect(
            !fromRequirements.isEmpty || !pinnedArtifacts.isEmpty,
            "README advertises no installable version; update the snippets or this guard"
        )

        let tags = try Self.remoteVersionTags()
        let output = try Self.evaluateJS(
            #"""
            import { pathToFileURL } from 'node:url';
            const m = await import(pathToFileURL(process.env.RELEASE_SCRIPT_PATH));
            const tags = JSON.parse(process.env.RELEASE_TAGS);
            const greatest = m.greatestVersionTag(tags);
            const problems = [];
            for (const version of JSON.parse(process.env.RELEASE_FROM_REQUIREMENTS)) {
                if (!m.isSemver(version)) { problems.push(`non-semver SPM requirement: ${version}`); continue; }
                // `from: "X.Y.Z"` resolves to the greatest tag inside
                // [X.Y.Z, (X+1).0.0) — SwiftPM excludes the next major from
                // the range, so a tag above it cannot satisfy the requirement.
                const nextMajor = `${Number(version.split('.')[0]) + 1}.0.0`;
                const eligible = tags.filter((tag) =>
                    /^v\d+\.\d+\.\d+$/.test(tag)
                        && m.compareSemver(tag.slice(1), version) >= 0
                        && m.compareSemver(tag.slice(1), nextMajor) < 0
                );
                if (eligible.length === 0) {
                    problems.push(
                        `SPM requirement from: "${version}" cannot resolve: no published tag in [${version}, ${nextMajor})`
                    );
                }
            }
            for (const version of JSON.parse(process.env.RELEASE_PINNED_ARTIFACTS)) {
                if (!m.isSemver(version)) { problems.push(`non-semver pinned artifact version: ${version}`); continue; }
                if (!tags.includes(`v${version}`)) {
                    problems.push(
                        `binary target pins CupThreadFeedback-${version}.xcframework.zip but tag v${version} does not exist on origin`
                    );
                }
            }
            console.log(JSON.stringify({ greatest, problems }));
            """#,
            environment: [
                "RELEASE_TAGS": Self.jsonArray(tags),
                "RELEASE_FROM_REQUIREMENTS": Self.jsonArray(fromRequirements),
                "RELEASE_PINNED_ARTIFACTS": Self.jsonArray(pinnedArtifacts)
            ]
        )
        let data = try #require(output.data(using: .utf8), "expected JSON, got: \(output)")
        let verdict = try JSONDecoder().decode(Verdict.self, from: data)
        guard verdict.problems.isEmpty else {
            let header = "README install requirements do not resolve against origin (greatest tag: \(verdict.greatest ?? "none")):"
            Issue.record("\(header) \(verdict.problems.joined(separator: "; "))")
            return
        }
    }

    // MARK: - README parsing

    /// The `from: "…"` requirements the README instructs consumers to add
    /// (the SwiftPM source-package channel). Captures any quoted value so a
    /// malformed version reaches the guard's syntax check instead of
    /// silently escaping it.
    private static func readmeFromRequirements(_ readme: String) -> [String] {
        readme.matches(of: /from:\s*"([^"]+)"/).map { String($0.1) }
    }

    /// The versions pinned by the README's binary-target artifact URLs
    /// (`CupThreadFeedback-….xcframework.zip`), likewise captured verbatim
    /// so non-semver pins are rejected rather than ignored.
    private static func readmePinnedArtifactVersions(_ readme: String) -> [String] {
        readme.matches(of: /CupThreadFeedback-([^\/"]+)\.xcframework\.zip/).map { String($0.1) }
    }

    // MARK: - Repository tag state

    /// Lists the tags that actually exist on origin. The remote is probed —
    /// not the local clone — because CI checks out a single commit without
    /// tags, and a stale local clone must not green-light a stale README.
    private static func remoteVersionTags() throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "ls-remote", "--tags", "origin"]
        // Resolve `origin` against this checkout even when a runner starts
        // the test executable from another directory.
        process.currentDirectoryURL = try repoRoot()
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            Issue.record("failed to launch git ls-remote: \(error)")
            return []
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(
            process.terminationStatus == 0,
            "git ls-remote --tags origin failed with \(process.terminationStatus); the README guard needs the real tag state"
        )
        let output = String(bytes: data, encoding: .utf8) ?? ""
        var tags = Set<String>()
        for line in output.split(separator: "\n") {
            guard let reference = line.split(separator: "\t", maxSplits: 1).last,
                  reference.hasPrefix("refs/tags/") else { continue }
            // Annotated tags also list a peeled `^{}` entry for the same name.
            tags.insert(
                reference.dropFirst("refs/tags/".count)
                    .replacingOccurrences(of: "^{}", with: "")
            )
        }
        return tags.sorted()
    }

    // MARK: - node runner (mirrors ReleasePreflightTests)

    private static func repoRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            directory.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("scripts/release.mjs").path) {
                return directory
            }
        }
        try #require(false, "Could not locate scripts/release.mjs by walking up from \(#filePath)")
        return URL(fileURLWithPath: #filePath) // unreachable; #require throws first
    }

    private static func evaluateJS(
        _ expression: String,
        environment: [String: String]
    ) throws -> String {
        let scriptPath = try repoRoot().appendingPathComponent("scripts/release.mjs").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "--input-type=module", "-e", expression]
        var environmentCopy = ProcessInfo.processInfo.environment
        environmentCopy["RELEASE_SCRIPT_PATH"] = scriptPath
        for (key, value) in environment {
            environmentCopy[key] = value
        }
        process.environment = environmentCopy
        let stdout = Pipe()
        process.standardOutput = stdout
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            Issue.record("failed to launch node: \(error)")
            return ""
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(bytes: data, encoding: .utf8) ?? ""
        let errorOutput = String(bytes: errorData, encoding: .utf8) ?? ""
        try #require(
            process.terminationStatus == 0,
            "node exited \(process.terminationStatus): \(output)\(errorOutput)"
        )
        return output
    }

    private static func jsonArray(_ values: [String]) -> String {
        let encoded = values.map { value -> String in
            let data = try? JSONEncoder().encode(value)
            return String(bytes: data ?? Data("null".utf8), encoding: .utf8) ?? "null"
        }
        return "[\(encoded.joined(separator: ","))]"
    }
}
