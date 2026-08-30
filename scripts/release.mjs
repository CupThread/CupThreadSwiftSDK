#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import readline from "node:readline/promises";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const R2_BUCKET = process.env.R2_BUCKET || "cupthread-sdks";
const CDN_BASE = process.env.CDN_BASE || "https://cdn.cupthread.com";

function parseArgs(argv) {
  const args = { dryRun: false, skipTests: false, yes: false, version: null, skipUpload: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--version") args.version = argv[++i];
    else if (arg === "--dry-run") args.dryRun = true;
    else if (arg === "--skip-tests") args.skipTests = true;
    else if (arg === "--skip-upload") args.skipUpload = true;
    else if (arg === "--yes") args.yes = true;
    else fail(`Unknown argument: ${arg}`);
  }
  if (!args.version || !/^\d+\.\d+\.\d+$/.test(args.version)) {
    fail("--version must be specified as semver, e.g. --version 0.1.0");
  }
  return args;
}

function fail(message) {
  console.error(`✗ ${message}`);
  process.exit(1);
}

function run(cmd, args, opts = {}) {
  console.log(`  $ ${cmd} ${args.join(" ")}`);
  const result = spawnSync(cmd, args, {
    cwd: opts.cwd ?? ROOT,
    stdio: opts.capture ? ["ignore", "pipe", "inherit"] : "inherit",
    encoding: "utf8"
  });
  if (result.status !== 0) fail(`Command failed (${result.status}): ${cmd} ${args.join(" ")}`);
  return result.stdout;
}

function sha256(file) {
  const hash = createHash("sha256");
  hash.update(readFileSync(file));
  return hash.digest("hex");
}

function humanSize(bytes) {
  if (bytes >= 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${Math.max(1, Math.round(bytes / 1024))} KB`;
}

const APPLE_SLICES = [
  { name: "ios", destination: "generic/platform=iOS" },
  { name: "ios-simulator", destination: "generic/platform=iOS Simulator" },
  { name: "macos", destination: "generic/platform=macOS" },
  { name: "visionos", destination: "generic/platform=visionOS" },
  { name: "visionos-simulator", destination: "generic/platform=visionOS Simulator" },
  { name: "tvos", destination: "generic/platform=tvOS" },
  { name: "tvos-simulator", destination: "generic/platform=tvOS Simulator" }
];
const FRAMEWORK_PATH = "Products/usr/local/lib/CupThreadFeedback.framework";

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const version = args.version;

  if (!args.dryRun && !args.yes) {
    if (!process.stdout.isTTY) fail("Refusing to publish without --yes (or use --dry-run).");
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    const answer = await rl.question(`Release Apple SDK v${version} to ${CDN_BASE} + GitHub? [y/N] `);
    rl.close();
    if (!/^y(es)?$/i.test(answer.trim())) fail("Aborted.");
  }

  console.log(`\n🍎 Building CupThread Apple SDK v${version}`);
  const work = path.join(ROOT, "build/release");
  rmSync(work, { recursive: true, force: true });
  mkdirSync(work, { recursive: true });

  if (!args.skipTests) {
    console.log("• swift test");
    run("swift", ["test"], { cwd: ROOT });
  }

  console.log("• archiving platform slices");
  const frameworks = [];
  for (const slice of APPLE_SLICES) {
    run("xcodebuild", [
      "archive",
      "-scheme", "CupThreadFeedback",
      "-destination", slice.destination,
      "-archivePath", path.join(work, `${slice.name}.xcarchive`),
      "SKIP_INSTALL=NO",
      "BUILD_LIBRARY_FOR_DISTRIBUTION=YES",
      "-quiet"
    ], { cwd: ROOT });
    frameworks.push(path.join(work, `${slice.name}.xcarchive`, FRAMEWORK_PATH));
  }

  console.log("• assembling XCFramework");
  const xcframework = path.join(work, "CupThreadFeedback.xcframework");
  run("xcodebuild", ["-create-xcframework", ...frameworks.flatMap((f) => ["-framework", f]), "-output", xcframework]);

  const filename = `CupThreadFeedback-${version}.xcframework.zip`;
  const zipPath = path.join(work, filename);
  run("ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", xcframework, zipPath]);

  const artifact = {
    name: "XCFramework (iOS · macOS · visionOS · tvOS)",
    filename,
    url: `${CDN_BASE}/sdks/apple/${filename}`,
    size: humanSize(statSync(zipPath).size),
    sha256: sha256(zipPath)
  };
  console.log(`  ${filename}  ${artifact.size}  sha256:${artifact.sha256}`);

  const releaseInfo = {
    sdk: "apple",
    version,
    date: new Date().toISOString().slice(0, 10),
    artifact,
    notes: [
      `CupThread Apple SDK v${version}`,
      "SwiftUI surfaces: roadmap board, What's New, feature requests, feedback composer.",
      "iOS 17+ · macOS 14+ (universal arm64 + x86_64) · visionOS 1.0+ · tvOS 17+.",
      `Binary target with checksum ${artifact.sha256}.`
    ]
  };

  const infoFile = path.join(work, "release-info.json");
  writeFileSync(infoFile, JSON.stringify(releaseInfo, null, 2) + "\n");

  if (args.dryRun) {
    console.log(`\n  [dry-run] Apple SDK v${version} built successfully.`);
    return;
  }

  if (!args.skipUpload) {
    console.log("• uploading to R2");
    run("npx", ["wrangler", "r2", "object", "put", `${R2_BUCKET}/sdks/apple/${filename}`,
      "--file", zipPath, "--remote", "--content-type", "application/zip"]);
  }

  console.log("• tagging and creating GitHub release");
  const tag = `v${version}`;
  run("git", ["tag", "-a", tag, "-m", `Release ${tag}`]);
  run("git", ["push", "origin", tag]);
  run("gh", ["release", "create", tag,
    "--title", `Apple SDK v${version}`,
    "--notes", releaseInfo.notes.map((n) => `- ${n}`).join("\n"),
    zipPath]);

  console.log(`\n✓ Apple SDK v${version} successfully released!`);
}

main().catch((err) => fail(err.stack || err.message));
