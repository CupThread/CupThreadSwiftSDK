import Foundation
import Testing

/// Pins the remote probe interpretation layer of `scripts/release.mjs`
/// (issue #583): a transient probe failure — DNS blip, timeout, 5xx, a `gh`
/// token that expired minutes after the preflight's auth check — must surface
/// as an explicit "unknown" instead of being folded into a verified "does not
/// exist", which once let a rerun overwrite a published, checksum-pinned CDN
/// artifact while the script exited 0. The readiness evaluation's fail-closed
/// handling of unknown probe facts is pinned by `ReleasePreflightTests`.
@Suite("Release probe interpretation")
struct ReleaseProbeInterpretationTests {
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

    private func runNode(_ arguments: [String]) -> NodeResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node"] + arguments
        var environmentCopy = ProcessInfo.processInfo.environment
        environmentCopy["RELEASE_SCRIPT_PATH"] = try? Self.repoRoot().appendingPathComponent("scripts/release.mjs").path
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
        let result = runNode(["--input-type=module", "-e", expression])
        #expect(result.status == 0, "node exited \(result.status)\nstdout: \(result.stdout)\nstderr: \(result.stderr)")
        guard result.status == 0 else { return "" }
        return result.stdout
    }

    // MARK: - CDN probe interpretation

    private struct InterpretedCdnOutcome: Decodable {
        let exists: Bool? // nil marks "could not determine"
        let sha256: String?
        let error: String?
    }

    private struct CdnOutcomeRow: Decodable {
        let name: String
        let result: InterpretedCdnOutcome
    }

    private static let cdnOutcomeCasesScript = #"""
    import { pathToFileURL } from 'node:url';
    const m = await import(pathToFileURL(process.env.RELEASE_SCRIPT_PATH));
    const SHA = 'a'.repeat(64);
    const outcomes = {
        ok200: { ok: true, status: 0, stdout: '200', stderr: '', error: null, sha256: SHA },
        okAfterRedirect: { ok: true, status: 0, stdout: '301\n200', stderr: '', error: null, sha256: SHA },
        verified404: { ok: true, status: 0, stdout: '404', stderr: '', error: null, sha256: null },
        serverError500: { ok: true, status: 0, stdout: '500', stderr: '', error: null, sha256: null },
        forbidden403: { ok: true, status: 0, stdout: '403', stderr: '', error: null, sha256: null },
        dnsFailure: {
            ok: false, status: 6, stdout: '000',
            stderr: 'curl: (6) Could not resolve host: cdn.invalid', error: null, sha256: null
        },
        timeout: { ok: false, status: 28, stdout: '000', stderr: 'curl: (28) Operation timed out', error: null, sha256: null },
        spawnFailure: { ok: false, status: null, stdout: '', stderr: '', error: 'spawn curl ENOENT', sha256: null },
        noStatusCode: { ok: true, status: 0, stdout: '', stderr: '', error: null, sha256: null }
    };
    const results = Object.entries(outcomes).map(([name, outcome]) => ({ name, result: m.interpretCdnProbeOutcome(outcome) }));
    console.log(JSON.stringify(results));
    """#

    /// Only a 2xx response verifies presence and only a 404 verifies absence;
    /// every other curl outcome (5xx, 403, DNS failure, timeout, spawn error)
    /// must come back as unknown-with-error so publication cannot act on it.
    @Test func cdnProbeOutcomesSeparateVerifiedAbsenceFromUnknown() throws {
        let output = try evaluateJS(Self.cdnOutcomeCasesScript)
        let data = try #require(output.data(using: .utf8), "expected JSON, got: \(output)")
        let rows = try JSONDecoder().decode([CdnOutcomeRow].self, from: data)
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0.result) })
        let sha = String(repeating: "a", count: 64)

        let present = try #require(byName["ok200"])
        #expect(present.exists == true)
        #expect(present.sha256 == sha)
        #expect(present.error == nil)

        let afterRedirect = try #require(byName["okAfterRedirect"])
        #expect(afterRedirect.exists == true, "the last http_code line after redirects decides")
        #expect(afterRedirect.sha256 == sha)

        let absent = try #require(byName["verified404"])
        #expect(absent.exists == false, "404 is the one outcome that verifies absence")
        #expect(absent.error == nil)

        for name in ["serverError500", "forbidden403", "dnsFailure", "timeout", "spawnFailure", "noStatusCode"] {
            let unknown = try #require(byName[name])
            #expect(unknown.exists == nil, "\(name): a non-2xx, non-404 outcome must be unknown")
            #expect(unknown.sha256 == nil)
            #expect(unknown.error?.isEmpty == false, "\(name): unknown outcomes must carry the probe's error detail")
        }
        #expect(byName["serverError500"]?.error?.contains("HTTP 500") == true)
        #expect(byName["forbidden403"]?.error?.contains("HTTP 403") == true)
        #expect(byName["dnsFailure"]?.error?.contains("Could not resolve host") == true)
        #expect(byName["timeout"]?.error?.contains("Operation timed out") == true)
        #expect(byName["spawnFailure"]?.error?.contains("ENOENT") == true)
        #expect(byName["noStatusCode"]?.error?.contains("no HTTP status code") == true)
    }

    // MARK: - cdnObjectInfo end to end with an injected probe

    private struct CdnProbeHarness: Decodable {
        let digest: String
        let observedCmd: String
        let observedUrlNamesArtifact: Bool
        let observedHasMaxTime: Bool
        let observedWritesHttpCode: Bool
        let present: InterpretedCdnOutcome
        let absent: InterpretedCdnOutcome
        let unknown: InterpretedCdnOutcome
    }

    private static let cdnObjectInfoScript = #"""
    import { pathToFileURL } from 'node:url';
    import { createHash } from 'node:crypto';
    import { writeFileSync } from 'node:fs';
    const m = await import(pathToFileURL(process.env.RELEASE_SCRIPT_PATH));
    const bytes = Buffer.from('published object bytes');
    let observed = null;
    const present = m.cdnObjectInfo('CupThreadFeedback-0.1.1.xcframework.zip', (cmd, args) => {
        observed = {
            cmd,
            url: args[args.length - 1],
            hasMaxTime: args.includes('--max-time'),
            writesHttpCode: args.includes('--write-out'),
            outFile: args[args.indexOf('-o') + 1]
        };
        writeFileSync(observed.outFile, bytes);
        return { ok: true, status: 0, stdout: '200', stderr: '', error: null };
    });
    const digest = createHash('sha256').update(bytes).digest('hex');
    const artifact = 'CupThreadFeedback-0.1.1.xcframework.zip';
    const ok404 = () => ({ ok: true, status: 0, stdout: '404', stderr: '', error: null });
    const timedOut = () => ({ ok: false, status: 28, stdout: '000', stderr: 'curl: (28) Operation timed out', error: null });
    const absent = m.cdnObjectInfo(artifact, ok404);
    const unknown = m.cdnObjectInfo(artifact, timedOut);
    console.log(JSON.stringify({
        digest,
        observedCmd: observed.cmd,
        observedUrlNamesArtifact: observed.url.includes('CupThreadFeedback-0.1.1.xcframework.zip'),
        observedHasMaxTime: observed.hasMaxTime,
        observedWritesHttpCode: observed.writesHttpCode,
        present,
        absent,
        unknown
    }));
    """#

    /// `cdnObjectInfo` must probe with curl plus the HTTP-code write-out (so
    /// the interpreter, not the exit status alone, classifies the response),
    /// hash the downloaded body only on success, and pass every outcome
    /// through the interpretation unchanged.
    @Test func cdnObjectInfoProbesWithHttpCodeAndHashesOnlySuccessfulBodies() throws {
        let output = try evaluateJS(Self.cdnObjectInfoScript)
        let data = try #require(output.data(using: .utf8), "expected JSON, got: \(output)")
        let harness = try JSONDecoder().decode(CdnProbeHarness.self, from: data)

        #expect(harness.observedCmd == "curl")
        #expect(harness.observedUrlNamesArtifact, "the probe must request the exact artifact filename")
        #expect(harness.observedHasMaxTime, "the probe must stay bounded by --max-time")
        #expect(harness.observedWritesHttpCode, "the probe must carry the --write-out http_code seam")

        #expect(harness.present.exists == true)
        #expect(harness.present.sha256 == harness.digest, "a successful probe reports the downloaded body's sha256")
        #expect(harness.absent.exists == false)
        #expect(harness.absent.sha256 == nil, "a 404 never reports a checksum")
        #expect(harness.unknown.exists == nil)
        #expect(harness.unknown.error?.contains("Operation timed out") == true)
    }

    // MARK: - GitHub release probe interpretation

    private struct ReleaseInfo: Decodable {
        let isDraft: Bool
        let assetNames: [String]
        let bodySha256: String?
    }

    private struct GhProbeResult: Decodable {
        let release: ReleaseInfo? // nil marks verified absence or unknown
        let error: String?
    }

    private struct GhProbeHarness: Decodable {
        let ghCmd: String
        let ghSubcommand: String
        let requestsJsonFields: Bool
        let published: GhProbeResult
        let draft: GhProbeResult
        let notFound: GhProbeResult
        let authExpired: GhProbeResult
        let malformedOutput: GhProbeResult
    }

    private static let ghReleaseInfoScript = #"""
    import { pathToFileURL } from 'node:url';
    const m = await import(pathToFileURL(process.env.RELEASE_SCRIPT_PATH));
    const SHA = 'b'.repeat(64);
    let ghArgs = null;
    const published = m.githubReleaseInfo('v0.1.1', (cmd, args) => {
        ghArgs = { cmd, subcommand: args[0] + ' ' + args[1], requestsJsonFields: args.includes('isDraft,assets,body') };
        return {
            ok: true,
            status: 0,
            stdout: JSON.stringify({
                isDraft: false,
                assets: [{ name: 'CupThreadFeedback-0.1.1.xcframework.zip' }],
                body: '- Binary target with checksum ' + SHA + '.'
            }),
            stderr: '',
            error: null
        };
    });
    const draft = m.githubReleaseInfo('v0.1.1', () => ({
        ok: true,
        status: 0,
        stdout: JSON.stringify({ isDraft: true, assets: [], body: 'no checksum in these notes' }),
        stderr: '',
        error: null
    }));
    const notFound = m.githubReleaseInfo('v0.1.1', () => ({ ok: false, status: 1, stdout: '', stderr: 'release not found', error: null }));
    const authExpired = m.githubReleaseInfo('v0.1.1', () => ({
        ok: false, status: 1, stdout: '', stderr: 'gh: HTTP 401: Bad credentials', error: null
    }));
    const malformedOutput = m.githubReleaseInfo('v0.1.1', () => ({ ok: true, status: 0, stdout: 'not json {', stderr: '', error: null }));
    console.log(JSON.stringify({
        ghCmd: ghArgs.cmd,
        ghSubcommand: ghArgs.subcommand,
        requestsJsonFields: ghArgs.requestsJsonFields,
        published,
        draft,
        notFound,
        authExpired,
        malformedOutput
    }));
    """#

    /// Only gh's "release not found" outcome verifies absence; an expired
    /// token or any other mid-run failure must become unknown-with-error —
    /// the old code mapped every failure to `null` ("no release") behind a
    /// comment claiming `requireGhAuth` covered the rest, which ran minutes
    /// earlier and covers nothing at probe time (issue #583).
    @Test func ghReleaseProbeOutcomesOnlyTrustAnExplicitNotFound() throws {
        let output = try evaluateJS(Self.ghReleaseInfoScript)
        let data = try #require(output.data(using: .utf8), "expected JSON, got: \(output)")
        let harness = try JSONDecoder().decode(GhProbeHarness.self, from: data)

        #expect(harness.ghCmd == "gh")
        #expect(harness.ghSubcommand == "release view")
        #expect(harness.requestsJsonFields)

        let sha = String(repeating: "b", count: 64)
        let published = try #require(harness.published.release)
        #expect(published.isDraft == false)
        #expect(published.assetNames == ["CupThreadFeedback-0.1.1.xcframework.zip"])
        #expect(published.bodySha256 == sha, "the checksum embedded in the release notes is extracted")
        #expect(harness.published.error == nil)

        let draft = try #require(harness.draft.release)
        #expect(draft.isDraft == true)
        #expect(draft.bodySha256 == nil)

        #expect(harness.notFound.release == nil, "not found verifies absence")
        #expect(harness.notFound.error == nil, "a verified absence is not an error")

        #expect(harness.authExpired.release == nil)
        #expect(harness.authExpired.error?.contains("401") == true, "an expired token mid-run must surface as unknown, not as absence")

        #expect(harness.malformedOutput.release == nil)
        #expect(harness.malformedOutput.error?.contains("parse") == true, "malformed successful output fails closed as unknown")
    }
}
