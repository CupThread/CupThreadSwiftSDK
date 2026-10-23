import Foundation
import Testing

/// Drives the pure commit decisions through the states a release run can
/// find: a tolerated pending version file, a fresh write, HEAD already at the
/// target version, regenerated content, and a tagged HEAD (issue #518).
private let versionCommitPlanScript = #"""
import { pathToFileURL } from 'node:url';
const m = await import(pathToFileURL(process.env.RELEASE_SCRIPT_PATH));
const failures = [];
function check(name, got, expected) {
    if (JSON.stringify(got) !== JSON.stringify(expected)) {
        failures.push({ name, got, expected });
    }
}
const planCases = [
    {
        name: 'toleratedPending',
        input: { fileMatchesTarget: true, headMatchesTarget: false },
        expected: { write: false, stage: true, commit: true }
    },
    {
        name: 'freshWrite',
        input: { fileMatchesTarget: false, headMatchesTarget: false },
        expected: { write: true, stage: true, commit: true }
    },
    {
        name: 'headAlreadyAtTarget',
        input: { fileMatchesTarget: true, headMatchesTarget: true },
        expected: { write: false, stage: false, commit: false }
    },
    {
        name: 'regeneratedContent',
        input: { fileMatchesTarget: false, headMatchesTarget: true },
        expected: { write: true, stage: true, commit: true }
    },
    {
        name: 'taggedHeadIsPinned',
        input: { fileMatchesTarget: false, headMatchesTarget: true, headTagged: true },
        expected: { write: true, stage: false, commit: false }
    }
];
for (const c of planCases) {
    check(c.name, m.planVersionFileCommit(c.input), c.expected);
}
check('tagOnStaleHeadBlocks', m.tagBlocksVersionBump({
    tagAtHead: true, headVersion: '1.2.2', version: '1.2.3'
}), true);
check('tagOnTargetHeadDoesNotBlock', m.tagBlocksVersionBump({
    tagAtHead: true, headVersion: '1.2.3', version: '1.2.3'
}), false);
check('untaggedHeadDoesNotBlock', m.tagBlocksVersionBump({
    tagAtHead: false, headVersion: '1.2.2', version: '1.2.3'
}), false);
check(
    'declarationIgnoresComments',
    m.declaredSDKVersion('// sdkVersion = "9.9.9"\npublic static let sdkVersion = "1.2.3"\n'),
    '1.2.3'
);
check('commentOnlyDeclaresNothing', m.declaredSDKVersion('// public static let sdkVersion = "9.9.9"\n'), null);
check(
    'canonicalHeadContentAccepted',
    m.versionFileContentProblem('1.2.3', m.sdkVersionFileContent('1.2.3')),
    null
);
const altered = m.sdkVersionFileContent('1.2.3').replace('cupthread-apple', 'cupthread-apple-edited');
check(
    'alteredHeadContentRejected',
    String(m.versionFileContentProblem('1.2.3', altered)).includes('differs'),
    true
);
console.log(JSON.stringify(failures.length === 0 ? { ok: true } : { ok: false, failures }));
"""#

/// Reproduces a run that died between writing `SDKVersion.swift` and
/// committing it, then asserts the rerun creates exactly one bump commit and
/// that the annotated tag names a commit carrying the target version
/// (issue #518).
private let versionCommitRerunScript = #"""
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const m = await import(pathToFileURL(process.env.RELEASE_SCRIPT_PATH));
const root = mkdtempSync(path.join(tmpdir(), 'cupthread-release-rerun-'));
const versionFile = path.join(root, 'Sources/CupThreadFeedback/SDKVersion.swift');
const git = (...args) => execFileSync('git', args, {
    cwd: root,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
});

mkdirSync(path.dirname(versionFile), { recursive: true });
git('init', '-q');
git('config', 'user.email', 'release-test@example.com');
git('config', 'user.name', 'Release Test');
git('config', 'commit.gpgsign', 'false');
git('config', 'tag.gpgsign', 'false');
writeFileSync(versionFile, m.sdkVersionFileContent('1.2.2'));
git('add', '.');
git('commit', '-qm', 'previous release');

const problemBefore = m.versionBumpCommitProblem('1.2.3', { root });

// Run 1 died after the version write and before the bump commit.
writeFileSync(versionFile, m.sdkVersionFileContent('1.2.3'));
const first = m.commitVersionFileIfNeeded('1.2.3', { root });
const firstProblem = m.versionBumpCommitProblem('1.2.3', { root });
const logAfterFirst = git('log', '--format=%s');
git('tag', '-a', 'v1.2.3', '-m', 'Release v1.2.3');
const tagged = git('show', 'v1.2.3:Sources/CupThreadFeedback/SDKVersion.swift');

// A rerun of the commit step recognizes the bump and stays a no-op.
const second = m.commitVersionFileIfNeeded('1.2.3', { root });
const logAfterSecond = git('log', '--format=%s');

const result = {
    firstCommitted: first.committed,
    firstVersion: first.version,
    firstProblem,
    problemBefore,
    secondCommitted: second.committed,
    commitsAfterFirst: logAfterFirst.trim().split('\n').length,
    commitsAfterSecond: logAfterSecond.trim().split('\n').length,
    tagDeclaresTarget: tagged.includes('sdkVersion = "1.2.3"'),
    versionFileStatus: git('status', '--porcelain')
};
console.log('RESULT:' + JSON.stringify(result));
"""#

/// Guards the release pipeline's preflight and idempotency rules by driving
/// the pure helpers exported from `scripts/release.mjs` with `node`. The
/// script's publication order (tag → draft release → R2 → CDN verification →
/// publish) leaves the repository half-published if a stage fails, so every
/// decision it makes — clean tree, branch/ancestry, version monotonicity,
/// tag/release/CDN collision and rerun recognition — is pinned here and runs
/// as part of the regular `swift test` gate (issue #11).
@Suite("Release preflight")
struct ReleasePreflightTests {
    private struct NodeResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private struct BatchResult: Decodable {
        struct Completed: Decodable {
            let tag: Bool
            let githubRelease: Bool
            let cdnObject: Bool

            var flags: [(name: String, value: Bool)] {
                [("tag", tag), ("githubRelease", githubRelease), ("cdnObject", cdnObject)]
            }
        }

        let name: String
        let errors: [String]
        let warnings: [String]
        let completed: Completed
    }

    private struct RerunResult: Decodable {
        let firstCommitted: Bool
        let firstVersion: String
        let firstProblem: String?
        let problemBefore: String?
        let secondCommitted: Bool
        let commitsAfterFirst: Int
        let commitsAfterSecond: Int
        let tagDeclaresTarget: Bool
        let versionFileStatus: String
    }

    private struct Expectation {
        let errorContains: [String]
        let warningContains: [String]
        let completed: Set<String>

        init(errorContains: [String] = [], warningContains: [String] = [], completed: Set<String> = []) {
            self.errorContains = errorContains
            self.warningContains = warningContains
            self.completed = completed
        }
    }

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

    private func runNode(_ arguments: [String], environment: [String: String] = [:]) -> NodeResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node"] + arguments
        var environmentCopy = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            environmentCopy[key] = value
        }
        process.environment = environmentCopy
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return NodeResult(status: -1, stdout: "", stderr: "failed to launch node: \(error)")
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let out = String(bytes: outData, encoding: .utf8) ?? ""
        let err = String(bytes: errData, encoding: .utf8) ?? ""
        return NodeResult(status: process.terminationStatus, stdout: out, stderr: err)
    }

    /// Evaluates a JS module expression with `RELEASE_SCRIPT_PATH` pointing
    /// at the repo's release script and returns its stdout, failing the test
    /// if node exits non-zero.
    private func evaluateJS(_ expression: String) throws -> String {
        let scriptPath = try Self.repoRoot().appendingPathComponent("scripts/release.mjs").path
        let result = runNode(["--input-type=module", "-e", expression], environment: ["RELEASE_SCRIPT_PATH": scriptPath])
        #expect(result.status == 0, "node exited \(result.status)\nstdout: \(result.stdout)\nstderr: \(result.stderr)")
        guard result.status == 0 else { return "" }
        return result.stdout
    }

    @Test func semverHelpersOrderAndValidate() throws {
        let output = try evaluateJS("""
        import { pathToFileURL } from 'node:url';
        const m = await import(pathToFileURL(process.env.RELEASE_SCRIPT_PATH));
        function check(rows) {
            for (const row of rows) {
                if (row.got !== row.expected) {
                    console.log(JSON.stringify({ ok: false, detail: row }));
                    process.exit(0);
                }
            }
        }
        check([
            { got: m.compareSemver('0.1.0', '0.1.1'), expected: -1 },
            { got: m.compareSemver('0.1.1', '0.1.0'), expected: 1 },
            { got: m.compareSemver('1.0.0', '1.0.0'), expected: 0 },
            { got: m.compareSemver('0.10.0', '0.9.0'), expected: 1 },
            { got: m.compareSemver('2.0.0', '10.0.0'), expected: -1 },
            { got: m.greatestVersionTag(['v0.1.0', 'v0.2.0', 'v0.1.9']), expected: 'v0.2.0' },
            { got: m.greatestVersionTag(['not-a-version', 'v1.2.3']), expected: 'v1.2.3' },
            { got: m.greatestVersionTag(['v0.0.1', 'v0.0.2', 'v0.0.10']), expected: 'v0.0.10' },
            { got: m.greatestVersionTag([]), expected: null },
            { got: m.isSemver('0.1.0'), expected: true },
            { got: m.isSemver('0.1'), expected: false },
            { got: m.isSemver('0.1.0-beta'), expected: false },
            { got: m.isSemver(''), expected: false },
            { got: m.artifactFilename('1.2.3'), expected: 'CupThreadFeedback-1.2.3.xcframework.zip' },
            { got: m.sdkVersionFileContent('9.9.9').includes('sdkVersion = "9.9.9"'), expected: true }
        ]);
        console.log(JSON.stringify({ ok: true }));
        """)
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == #"{"ok":true}"#, "unexpected helper result: \(output)")
    }

    @Test func versionCommitDecisionsCoverPendingRerunAndTaggedStates() throws {
        let output = try evaluateJS(versionCommitPlanScript)
        #expect(
            output.trimmingCharacters(in: .whitespacesAndNewlines) == #"{"ok":true}"#,
            "unexpected commit decisions: \(output)"
        )
    }

    @Test func rerunCommitsToleratedPendingVersionFileBeforeTagging() throws {
        let output = try evaluateJS(versionCommitRerunScript)
        let line = try #require(
            output.split(separator: "\n").last(where: { $0.hasPrefix("RESULT:") }),
            "expected a RESULT marker from the rerun simulation, got: \(output)"
        )
        let result = try JSONDecoder().decode(RerunResult.self, from: Data(line.dropFirst("RESULT:".count).utf8))
        let staleHead = try #require(result.problemBefore, "a tag on a stale HEAD must be rejected")
        #expect(staleHead.contains(#""1.2.2""#), "the rejection must name the version found in HEAD; got: \(staleHead)")
        #expect(staleHead.contains("refusing to tag"), "the rejection must stop the tag; got: \(staleHead)")
        #expect(result.firstCommitted, "the tolerated pending version file must be committed before the build")
        #expect(result.firstVersion == "1.2.3")
        #expect(result.firstProblem == nil, "HEAD must carry the bump before tagging; got: \(result.firstProblem ?? "nil")")
        #expect(!result.secondCommitted, "a rerun must not create a second bump commit")
        #expect(result.commitsAfterFirst == 2, "expected the previous release plus one version bump commit")
        #expect(result.commitsAfterSecond == 2, "a rerun must not add commits")
        #expect(result.tagDeclaresTarget, "the annotated tag must resolve to a commit with the target SDKVersion.swift")
        #expect(result.versionFileStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func readinessDecisionsCoverPreflightAndRerunStates() throws {
        let output = try evaluateJS(Self.scenarioScript)
        let results = try #require(decodeBatch(output), "expected a JSON batch, got: \(output)")
        let expectations = Self.scenarioExpectations

        var seen = Set<String>()
        for result in results {
            seen.insert(result.name)
            guard let expectation = expectations[result.name] else {
                Issue.record("Unexpected scenario returned by the script: \(result.name)")
                continue
            }
            for fragment in expectation.errorContains {
                #expect(
                    result.errors.contains { $0.contains(fragment) },
                    "[\(result.name)] expected an error containing '\(fragment)'; got: \(result.errors)"
                )
            }
            for fragment in expectation.warningContains {
                #expect(
                    result.warnings.contains { $0.contains(fragment) },
                    "[\(result.name)] expected a warning containing '\(fragment)'; got: \(result.warnings)"
                )
            }
            #expect(
                result.errors.count == expectation.errorContains.count,
                "[\(result.name)] unexpected extra errors: \(result.errors)"
            )
            for flag in result.completed.flags {
                #expect(
                    flag.value == expectation.completed.contains(flag.name),
                    "[\(result.name)] completed.\(flag.name) expected \(expectation.completed.contains(flag.name))"
                )
            }
        }
        #expect(
            seen == Set(expectations.keys),
            "scenario name drift between test and script; missing: \(Set(expectations.keys).subtracting(seen))"
        )
    }

    @Test func importingTheScriptDoesNotRunTheRelease() throws {
        let output = try evaluateJS("""
        import { pathToFileURL } from 'node:url';
        const m = await import(pathToFileURL(process.env.RELEASE_SCRIPT_PATH));
        console.log('imported:', typeof m.evaluateReleaseReadiness, typeof m.syncSDKVersion);
        """)
        #expect(
            output.contains("imported: function"),
            "importing release.mjs must be side-effect free (no build, no publication); got: \(output)"
        )
    }

    @Test func cliStillRejectsInvalidVersions() throws {
        let scriptPath = try Self.repoRoot().appendingPathComponent("scripts/release.mjs").path
        let result = runNode([scriptPath, "--version", "banana", "--dry-run"])
        #expect(result.status == 1, "invalid version must exit 1; got \(result.status), stderr: \(result.stderr)")
        #expect(result.stderr.contains("semver"), "expected a semver rejection message; got: \(result.stderr)")
    }

    private func decodeBatch(_ output: String) -> [BatchResult]? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([BatchResult].self, from: data)
    }

    // The readiness scenarios are batched into a single `node` invocation;
    // the script prints one JSON object per scenario.
    private static let scenarioScript = #"""
    import { pathToFileURL } from 'node:url';
    const m = await import(pathToFileURL(process.env.RELEASE_SCRIPT_PATH));
    const HEAD = 'a'.repeat(40);
    const OTHER = 'b'.repeat(40);
    const ARTIFACT = 'a'.repeat(64);
    const OTHER_ARTIFACT = 'b'.repeat(64);
    const ASSET = 'CupThreadFeedback-0.1.1.xcframework.zip';
    function base(overrides) {
        return Object.assign({
            version: '0.1.1',
            branch: 'main',
            statusLines: [],
            versionFilePendingRelease: false,
            headSha: HEAD,
            originMainSha: HEAD,
            originMainIsAncestorOfHead: true,
            fetchError: null,
            latestTag: null,
            localTagCommitSha: null,
            remoteTagCommitSha: null,
            remoteTagProbeError: null,
            githubRelease: null,
            cdnObject: null,
            artifactSha256: null
        }, overrides);
    }
    const publishedRelease = { isDraft: false, assetNames: [ASSET], bodySha256: ARTIFACT };
    const scenarios = [
        { name: 'freshRelease', facts: base({}) },
        { name: 'dirtyTree', facts: base({ statusLines: [' M README.md'] }) },
        { name: 'pendingVersionFileTolerated', facts: base({
            statusLines: [' M Sources/CupThreadFeedback/SDKVersion.swift'],
            versionFilePendingRelease: true
        }) },
        { name: 'pendingVersionFileWrongContent', facts: base({
            statusLines: [' M Sources/CupThreadFeedback/SDKVersion.swift'],
            versionFilePendingRelease: false
        }) },
        { name: 'wrongBranch', facts: base({ branch: 'feature/x' }) },
        { name: 'behindOrigin', facts: base({ originMainSha: OTHER, originMainIsAncestorOfHead: false }) },
        { name: 'fetchFailure', facts: base({ fetchError: 'network down', originMainSha: null }) },
        { name: 'notNewerThanLatestTag', facts: base({ latestTag: 'v0.2.0' }) },
        { name: 'olderThanLatestTag', facts: base({ latestTag: 'v1.0.0' }) },
        { name: 'equalLatestTagIsOwnRerun', facts: base({ latestTag: 'v0.1.1' }) },
        { name: 'reservedVersion', facts: base({ version: '0.1.0' }) },
        { name: 'foreignLocalTag', facts: base({ localTagCommitSha: OTHER }) },
        { name: 'foreignRemoteTag', facts: base({ remoteTagCommitSha: OTHER }) },
        { name: 'remoteTagProbeFailure', facts: base({ remoteTagProbeError: 'offline' }) },
        { name: 'localTagAtHeadUnpushed', facts: base({ localTagCommitSha: HEAD }) },
        { name: 'tagFullyPushed', facts: base({ localTagCommitSha: HEAD, remoteTagCommitSha: HEAD }) },
        { name: 'draftReleaseExists', facts: base({ githubRelease: { isDraft: true, assetNames: [], bodySha256: null } }) },
        { name: 'publishedReleaseWithoutArtifactShaOnlyWarns', facts: base({
            githubRelease: { isDraft: false, assetNames: [], bodySha256: null }
        }) },
        { name: 'publishedReleaseMatchesArtifact', facts: base({ artifactSha256: ARTIFACT, githubRelease: publishedRelease }) },
        { name: 'publishedReleaseMissingAsset', facts: base({
            artifactSha256: ARTIFACT,
            githubRelease: { isDraft: false, assetNames: [], bodySha256: null }
        }) },
        { name: 'publishedReleaseChecksumMismatch', facts: base({
            artifactSha256: ARTIFACT,
            githubRelease: { isDraft: false, assetNames: [ASSET], bodySha256: OTHER_ARTIFACT }
        }) },
        { name: 'cdnExistsBeforeBuildOnlyWarns', facts: base({ cdnObject: { exists: true, sha256: OTHER_ARTIFACT } }) },
        { name: 'cdnObjectMatchesArtifact', facts: base({ artifactSha256: ARTIFACT, cdnObject: { exists: true, sha256: ARTIFACT } }) },
        { name: 'cdnMismatchWithDraftOverwrites', facts: base({
            artifactSha256: ARTIFACT,
            cdnObject: { exists: true, sha256: OTHER_ARTIFACT }
        }) },
        { name: 'cdnMismatchWithPublishedRejected', facts: base({
            artifactSha256: ARTIFACT,
            cdnObject: { exists: true, sha256: OTHER_ARTIFACT },
            githubRelease: publishedRelease
        }) },
        { name: 'everythingDoneCompletes', facts: base({
            artifactSha256: ARTIFACT,
            cdnObject: { exists: true, sha256: ARTIFACT },
            localTagCommitSha: HEAD,
            remoteTagCommitSha: HEAD,
            githubRelease: publishedRelease
        }) }
    ];
    const results = scenarios.map((scenario) => {
        const decision = m.evaluateReleaseReadiness(scenario.facts);
        return { name: scenario.name, errors: decision.errors, warnings: decision.warnings, completed: decision.completed };
    });
    console.log(JSON.stringify(results));
    """#

    private static let scenarioExpectations: [String: Expectation] = [
        "freshRelease": Expectation(),
        "dirtyTree": Expectation(errorContains: ["not clean"]),
        "pendingVersionFileTolerated": Expectation(warningContains: ["previous release attempt"]),
        "pendingVersionFileWrongContent": Expectation(errorContains: ["not clean"]),
        "wrongBranch": Expectation(errorContains: ["must be cut from main"]),
        "behindOrigin": Expectation(errorContains: ["behind or diverged"]),
        "fetchFailure": Expectation(errorContains: ["Could not fetch origin"]),
        "notNewerThanLatestTag": Expectation(errorContains: ["not greater"]),
        "olderThanLatestTag": Expectation(errorContains: ["not greater"]),
        "equalLatestTagIsOwnRerun": Expectation(),
        "reservedVersion": Expectation(errorContains: ["reserved"]),
        "foreignLocalTag": Expectation(errorContains: ["exists locally"]),
        "foreignRemoteTag": Expectation(errorContains: ["already exists on origin"]),
        "remoteTagProbeFailure": Expectation(errorContains: ["Could not list remote tags"]),
        "localTagAtHeadUnpushed": Expectation(warningContains: ["has not been pushed"]),
        "tagFullyPushed": Expectation(completed: ["tag"]),
        "draftReleaseExists": Expectation(warningContains: ["draft GitHub release"]),
        "publishedReleaseWithoutArtifactShaOnlyWarns": Expectation(warningContains: ["already published"]),
        "publishedReleaseMatchesArtifact": Expectation(completed: ["githubRelease"]),
        "publishedReleaseMissingAsset": Expectation(errorContains: ["no CupThreadFeedback-0.1.1.xcframework.zip asset"]),
        "publishedReleaseChecksumMismatch": Expectation(errorContains: ["mismatched artifact"]),
        "cdnExistsBeforeBuildOnlyWarns": Expectation(warningContains: ["already exists"]),
        "cdnObjectMatchesArtifact": Expectation(completed: ["cdnObject"]),
        "cdnMismatchWithDraftOverwrites": Expectation(warningContains: ["overwrite it with the verified build"]),
        "cdnMismatchWithPublishedRejected": Expectation(
            errorContains: ["refusing to mutate a published artifact"],
            completed: ["githubRelease"]
        ),
        "everythingDoneCompletes": Expectation(completed: ["tag", "githubRelease", "cdnObject"])
    ]
}
