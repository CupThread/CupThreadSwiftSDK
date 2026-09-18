# Release Runbook (Apple SDK)

Operational guide for cutting a release with `scripts/release.mjs`. The
design goals (issue #11) are: **fail before publishing**, never leave a
half-published version, and make every rerun recognize work that already
completed while rejecting mismatched artifacts.

## Prerequisites

Before running the script:

1. The release build blockers are fixed (`#7`, `#8`).
2. Full `swift test` passes locally.
3. The latest `main` CI run is green (7-slice archive matrix + release
   dry-run + Demo UI test) — see the Testing Policy in `AGENTS.md`.
4. You are on `main`, in sync with `origin/main`, with a clean tree.
5. `gh` is authenticated (`gh auth status`); R2 credentials are configured
   for `wrangler` if the CDN artifact will be uploaded.

## Command

```sh
node scripts/release.mjs --version X.Y.Z          # interactive release
node scripts/release.mjs --version X.Y.Z --yes    # non-interactive
node scripts/release.mjs --version X.Y.Z --dry-run --skip-tests   # build-only verification (CI runs this)
```

`--dry-run` skips the preflight and all publication steps; it only proves
the seven slices build and verify. All state checks apply exclusively to
real publications.

## What the script does, in order

1. **Preflight** (publication only; fails fast before any prompt or build):
   - required tools present (`git`, `gh`, `swift`, `xcodebuild`, `curl`,
     `npx`, `libtool`, `lipo`, `nm`, `ditto`) and `gh` authenticated;
   - current branch is `main`;
   - working tree is clean (single tolerated exception below);
   - `origin/main` was fetched and is an ancestor of local `HEAD`;
   - `X.Y.Z` is plain semver, is greater than the latest `v*` tag, and is
     not a [reserved version](#reserved-versions);
   - no local or remote tag `vX.Y.Z` (a tag already at `HEAD` is recognized
     as a completed rerun step instead);
   - no existing GitHub release `vX.Y.Z` (a draft is recognized and reused);
   - no CDN object `CupThreadFeedback-X.Y.Z.xcframework.zip` (a matching
     object is recognized; an unpublished mismatching object is overwritten).
2. Syncs `Sources/CupThreadFeedback/SDKVersion.swift` to the version and
   commits it (`chore: bump SDK version to X.Y.Z`).
3. `swift test` (unless `--skip-tests`).
4. Archives all seven platform slices and verifies them (archs via `lipo`,
   symbols via `nm`, privacy manifest, swiftmodule interfaces), assembles the
   static XCFramework, stages the resource bundle, zips, and runs the
   consumer-probe package.
5. **Re-checks publication state with the fresh artifact's checksum**, then:
   1. tags `HEAD` (`vX.Y.Z`, annotated) and pushes the tag;
   2. creates a **draft** GitHub release with the artifact and release notes
      attached (or replaces the draft's assets);
   3. uploads the zip to R2 (`sdks/apple/<filename>`) and **downloads the
      published CDN object back and verifies its sha256**;
   4. publishes the draft release (`gh release edit vX.Y.Z --draft=false`).
6. Prints the manual next steps: push `main` (the version-bump commit is not
   pushed automatically) and update the README install snippet if this
   version becomes the documented one.

Nothing is public before step 5.4 — a failed stage always leaves at most a
tag plus a **draft** release, which are both recognized and reused by a rerun.

## Rerun semantics

A rerun of the same version recognizes already-completed matching stages:

| State found by the rerun | Behavior |
|---|---|
| Uncommitted generated `SDKVersion.swift` for this version | Tolerated; committed for this release |
| Local tag `vX.Y.Z` at `HEAD` | Kept; pushed if not on origin yet |
| Remote tag `vX.Y.Z` at `HEAD` | Recognized as done |
| Draft GitHub release `vX.Y.Z` | Reused; assets replaced (`--clobber`) |
| Published release with matching asset checksum | Recognized as done; left untouched |
| CDN object with matching sha256 | Upload skipped |
| All three (tag + release + CDN) match | “Already fully released” — exits 0 without touching anything |

Any **mismatch** (tag at another commit, published release without/with a
different artifact checksum, CDN object differing from a published release's
build) is a hard error. Mismatches are never silently reconciled once a
version is published.

## Preflight failures and remedies

| Error | Remedy |
|---|---|
| Missing tools | Install the listed tools (`brew install …`, Xcode CLTs). |
| `gh` not authenticated | `gh auth login`. |
| Wrong branch | `git switch main`. |
| Working tree not clean | Commit or stash. If the only dirt is `Sources/CupThreadFeedback/SDKVersion.swift` matching this release's version, the rerun tolerates it — otherwise discard it (`git checkout -- Sources/CupThreadFeedback/SDKVersion.swift`; the script regenerates it). |
| Behind or diverged from `origin/main` | `git merge --ff-only origin/main` (or rebase and force-with-lease on your own branch, then switch back to `main`). |
| Version not greater than latest tag | Pick a higher semver. |
| Reserved version (`0.1.0`) | Publish `0.1.1` or later — see below. |
| Tag exists elsewhere (local/remote) | Delete the local tag (`git tag -d vX.Y.Z`) only if you are sure it is from your own failed attempt; never move a remote tag. Release a new version instead. |

## Failure recovery per publication stage

- **Tag push fails** — nothing is published. Resolve the push, or
  `git tag -d vX.Y.Z` and fix the branch state, then rerun.
- **Draft release creation / asset upload fails** — the tag is pushed but
  nothing is public. Inspect with `gh release view vX.Y.Z`, fix, and rerun;
  the draft is reused and its assets replaced.
- **R2 upload fails** — tag + draft release exist, still nothing public.
  Fix wrangler credentials/connectivity and rerun.
- **CDN checksum verification fails** — the object exists but serves
  different bytes (or 404s). The release is still a draft; overwrite the R2
  object (rerun does this) and re-verify.
- **Publishing the draft fails** — everything else is verified. Check the
  asset one final time, then publish manually:
  `gh release edit vX.Y.Z --draft=false`.
- **After a successful release** — push `main`
  (`git push origin main`) so the version-bump commit is on the branch, and
  update the README install snippet if this version becomes the documented
  one. CI's `release-smoke` workflow (manual dispatch) then proves the
  published tag resolves as a source package and the published CDN artifact
  imports as a binary target.

## Reserved versions

`0.1.0` is permanently unreleasable: its CDN object
(`CupThreadFeedback-0.1.0.xcframework.zip`) predates this pipeline and its
exact source provenance cannot be established (issues #11, #55). It is never
repointed or overwritten; the first pipeline-released version is `0.1.1` or
later.
