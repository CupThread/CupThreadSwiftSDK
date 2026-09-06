#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
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
const RESOURCE_BUNDLE_NAME = "CupThreadFeedback_CupThreadFeedback.bundle";

// xcodebuild installs only the framework into the archive Products; the SPM
// resource bundle stays behind in the archive intermediates, so it must be
// copied in explicitly or Bundle.module ends in fatalError at first render.
function findBuiltResourceBundle(derivedData, sliceName) {
  const uninstalled = path.join(
    derivedData, "Build", "Intermediates.noindex", "ArchiveIntermediates",
    "CupThreadFeedback", "IntermediateBuildFilesPath", "UninstalledProducts"
  );
  const found = [];
  const visit = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      const full = path.join(dir, entry.name);
      if (entry.name === RESOURCE_BUNDLE_NAME) found.push(full);
      else visit(full);
    }
  };
  if (existsSync(uninstalled)) visit(uninstalled);
  if (found.length !== 1) {
    fail(`Expected exactly one ${RESOURCE_BUNDLE_NAME} under ${uninstalled} for ${sliceName}, found ${found.length}`);
  }
  return found[0];
}

// macOS frameworks are versioned (resources under Versions/A/Resources);
// iOS-style slices are flat (resources sit next to the binary and Info.plist).
function frameworkResourcesDir(framework) {
  const versioned = path.join(framework, "Versions", "A", "Resources");
  if (existsSync(versioned)) return versioned;
  return framework;
}

function embedResourceBundle(derivedData, framework, sliceName) {
  const bundle = findBuiltResourceBundle(derivedData, sliceName);
  const dest = path.join(frameworkResourcesDir(framework), RESOURCE_BUNDLE_NAME);
  run("cp", ["-R", bundle, dest]);
  // Adding files invalidates the archive-time CodeResources seal, so re-sign.
  run("codesign", ["--force", "--sign", "-", framework]);
}

function verifyEmbeddedResourceBundles(xcframework, sourceLprojs) {
  for (const entry of readdirSync(xcframework, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const framework = path.join(xcframework, entry.name, "CupThreadFeedback.framework");
    if (!existsSync(framework)) continue;
    const bundle = [
      path.join(framework, "Versions", "A", "Resources", RESOURCE_BUNDLE_NAME),
      path.join(framework, "Resources", RESOURCE_BUNDLE_NAME),
      path.join(framework, RESOURCE_BUNDLE_NAME)
    ].find((p) => existsSync(p));
    if (!bundle) {
      fail(`XCFramework slice ${entry.name} is missing ${RESOURCE_BUNDLE_NAME} — host apps would crash on first render`);
    }
    const resourcesDir = [
      path.join(bundle, "Contents", "Resources"),
      bundle
    ].find((p) => existsSync(path.join(p, "en.lproj")));
    if (!resourcesDir) {
      fail(`XCFramework slice ${entry.name} resource bundle has no en.lproj`);
    }
    if (!existsSync(path.join(resourcesDir, "en.lproj", "Localizable.strings"))) {
      fail(`XCFramework slice ${entry.name} resource bundle is missing en.lproj/Localizable.strings`);
    }
    const have = new Set(readdirSync(resourcesDir).filter((n) => n.endsWith(".lproj")));
    const missing = sourceLprojs.filter((lproj) => !have.has(lproj));
    if (missing.length > 0) {
      fail(`XCFramework slice ${entry.name} resource bundle missing localizations: ${missing.join(", ")}`);
    }
  }
}

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
    const derivedData = path.join(work, "derived-data", slice.name);
    run("xcodebuild", [
      "archive",
      "-scheme", "CupThreadFeedback",
      "-destination", slice.destination,
      "-archivePath", path.join(work, `${slice.name}.xcarchive`),
      "-derivedDataPath", derivedData,
      "SKIP_INSTALL=NO",
      "BUILD_LIBRARY_FOR_DISTRIBUTION=YES",
      "-quiet"
    ], { cwd: ROOT });
    const framework = path.join(work, `${slice.name}.xcarchive`, FRAMEWORK_PATH);
    embedResourceBundle(derivedData, framework, slice.name);
    frameworks.push(framework);
  }

  console.log("• verifying framework slices");
  for (const slice of APPLE_SLICES) {
    const framework = path.join(work, `${slice.name}.xcarchive`, FRAMEWORK_PATH);
    if (!existsSync(framework)) {
      fail(`Missing framework slice for ${slice.name} at: ${framework}`);
    }
  }

  console.log("• assembling XCFramework");
  const xcframework = path.join(work, "CupThreadFeedback.xcframework");
  run("xcodebuild", ["-create-xcframework", ...frameworks.flatMap((f) => ["-framework", f]), "-output", xcframework]);

  console.log("• verifying embedded resource bundles");
  const sourceLprojs = readdirSync(path.join(ROOT, "Sources", "CupThreadFeedback", "Resources"))
    .filter((name) => name.endsWith(".lproj"));
  verifyEmbeddedResourceBundles(xcframework, sourceLprojs);

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
