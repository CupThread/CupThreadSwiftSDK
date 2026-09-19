#!/usr/bin/env node
// Guards the repository's license identity (issue #12): the README declares
// MIT, so the root LICENSE must exist and carry the standard MIT grant, and
// the README license section must stay in sync with it. Wired into the CI
// lint job; also runnable locally:
//   node scripts/check-license.mjs

import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const LICENSE_PATH = path.join(ROOT, "LICENSE");
const README_PATH = path.join(ROOT, "README.md");

const failures = [];
const fail = (message) => failures.push(message);

if (!existsSync(LICENSE_PATH)) {
  fail("LICENSE is missing from the repository root.");
} else {
  const license = readFileSync(LICENSE_PATH, "utf8");
  if (!/^MIT License$/m.test(license)) {
    fail('LICENSE must be the standard MIT text (missing "MIT License" title).');
  }
  if (!license.includes("Permission is hereby granted, free of charge")) {
    fail('LICENSE must contain the standard MIT grant ("Permission is hereby granted, free of charge").');
  }
  if (!/^Copyright \(c\) \d{4} CupThread$/m.test(license)) {
    fail('LICENSE must carry a "Copyright (c) <year> CupThread" copyright line.');
  }
}

if (!existsSync(README_PATH)) {
  fail("README.md is missing from the repository root.");
} else {
  const readme = readFileSync(README_PATH, "utf8");
  const licenseSection = readme
    .split(/^## /m)
    .find((section) => section.startsWith("License"));
  if (!licenseSection) {
    fail('README.md must declare a "## License" section.');
  } else {
    if (!/\bMIT\b/.test(licenseSection)) {
      fail('The README "## License" section must declare the MIT license.');
    }
    if (!/\]\(LICENSE\)/.test(licenseSection)) {
      fail('The README "## License" section must link to the root LICENSE file (e.g. "[MIT](LICENSE)").');
    }
  }
}

if (failures.length > 0) {
  for (const failure of failures) {
    console.error(`✗ ${failure}`);
  }
  console.error("\nLicense identity diverged — fix the files above so README and LICENSE agree again.");
  process.exit(1);
}

console.log("✓ License identity is consistent: the root LICENSE carries the standard MIT grant and the README license section agrees with it.");
