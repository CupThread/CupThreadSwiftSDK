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

/// Reproduces an untagged HEAD that declares the target version but whose
/// `SDKVersion.swift` differs from the generated content: the bump commit must
/// still be created so the release tag carries the content the build used.
private let versionCommitAlteredHeadScript = #"""
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const m = await import(pathToFileURL(process.env.RELEASE_SCRIPT_PATH));
const root = mkdtempSync(path.join(tmpdir(), 'cupthread-release-altered-'));
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

// HEAD declares the target version, but the file content is not the
// generated document — for example a hand-edited copy that kept the version.
const altered = m.sdkVersionFileContent('1.2.3').replace('cupthread-apple', 'cupthread-apple-edited');
writeFileSync(versionFile, altered);
git('add', '.');
git('commit', '-qm', 'altered version file');

// The working tree carries the canonical generated file for the target.
writeFileSync(versionFile, m.sdkVersionFileContent('1.2.3'));

const first = m.commitVersionFileIfNeeded('1.2.3', { root });
const headContent = git('show', 'HEAD:Sources/CupThreadFeedback/SDKVersion.swift');
const commitsAfterFirst = git('log', '--format=%s').trim().split('\n').length;
const problem = m.versionBumpCommitProblem('1.2.3', { root });

const second = m.commitVersionFileIfNeeded('1.2.3', { root });
const commitsAfterSecond = git('log', '--format=%s').trim().split('\n').length;

const result = {
    firstCommitted: first.committed,
    headMatchesGenerated: headContent === m.sdkVersionFileContent('1.2.3'),
    commitsAfterFirst,
    problem,
    secondCommitted: second.committed,
    commitsAfterSecond,
    versionFileStatus: git('status', '--porcelain')
};
console.log('RESULT:' + JSON.stringify(result));
"""#

/// Pins the version-file commit plan and drives it in temporary git
/// repositories: the tolerated pending state, reruns, and altered HEAD
/// content all have to leave the release tag on the content the build used
/// (issue #518).
@Suite("Release version commit")
struct ReleaseVersionCommitTests {
    private struct NodeResult {
        let status: Int32
        let stdout: String
        let stderr: String
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

    private struct AlteredHeadResult: Decodable {
        let firstCommitted: Bool
        let headMatchesGenerated: Bool
        let commitsAfterFirst: Int
        let problem: String?
        let secondCommitted: Bool
        let commitsAfterSecond: Int
        let versionFileStatus: String
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

    @Test func alteredUntaggedHeadContentReceivesTheBumpCommit() throws {
        let output = try evaluateJS(versionCommitAlteredHeadScript)
        let line = try #require(
            output.split(separator: "\n").last(where: { $0.hasPrefix("RESULT:") }),
            "expected a RESULT marker from the altered-HEAD simulation, got: \(output)"
        )
        let result = try JSONDecoder().decode(AlteredHeadResult.self, from: Data(line.dropFirst("RESULT:".count).utf8))
        #expect(result.firstCommitted, "an untagged HEAD whose content differs from the generated file must receive a bump commit")
        #expect(result.headMatchesGenerated, "the bump commit must carry the generated version file")
        #expect(result.commitsAfterFirst == 3, "expected the previous release, the hand edit, and one version bump commit")
        #expect(result.problem == nil, "HEAD must carry the canonical file before tagging; got: \(result.problem ?? "nil")")
        #expect(!result.secondCommitted, "a rerun must not create a second bump commit")
        #expect(result.commitsAfterSecond == 3, "a rerun must not add commits")
        #expect(result.versionFileStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
