// Self-test probe for publish-ui.yml's npm credentials, run INSIDE the called
// workflow by self-test.yml's `publish-ui-*` jobs: as the `build-script` (so it
// sees exactly the npm config `npm ci` saw, one step earlier) and as the
// fixture package's `prepublishOnly` (so it sees exactly the config
// `npm publish` uses). Those jobs pass the dummy secrets below; nothing is
// installed from GitHub Packages and nothing is published (`dry-run`).
//
//   node check-npmrc.mjs install-github-packages
//     npm-github-packages: true — `npm ci` reads the runner's ~/.npmrc (no
//     setup-node npmrc shadows it) and that holds the CI_TOKEN credential for
//     npm.pkg.github.com.
//   node check-npmrc.mjs install-default
//     npm-github-packages: false (every existing caller) — setup-node's
//     registry npmrc is in force, as before, and CI_TOKEN is nowhere.
//   node check-npmrc.mjs publish
//     either way — `npm publish` reads setup-node's npmrc for public npm, which
//     authenticates with NODE_AUTH_TOKEN = NPM_TOKEN, and CI_TOKEN is in no
//     npmrc and no environment variable.
//
// Exits non-zero, naming every violated expectation, on a mismatch.
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

// The values self-test.yml passes as the CI_TOKEN and NPM_TOKEN secrets.
const CI_TOKEN = "publish-ui-selftest-ci-token";
const NPM_TOKEN = "publish-ui-selftest-npm-token";
const GITHUB_PACKAGES_AUTH = `//npm.pkg.github.com/:_authToken=${CI_TOKEN}`;
const PUBLIC_NPM_AUTH = "//registry.npmjs.org/:_authToken=${NODE_AUTH_TOKEN}";

const mode = process.argv[2];
const failures = [];
const expect = (ok, msg) => { if (!ok) failures.push(msg); };

// The npm that is running this script (npm_execpath), not whichever is on PATH.
const npm = (...args) =>
  execFileSync(process.execPath, [process.env.npm_execpath, ...args], { encoding: "utf8" }).trim();
const read = (path) => (existsSync(path) ? readFileSync(path, "utf8") : "");

const homeRc = join(homedir(), ".npmrc");
// The user npmrc npm reads: `npm config get userconfig` refuses ("protected"),
// so resolve it as npm does — the environment (setup-node's registry-url sets
// NPM_CONFIG_USERCONFIG; npm passes it on to scripts lowercased), else ~/.npmrc.
const userconfig = resolve(
  process.env.NPM_CONFIG_USERCONFIG || process.env.npm_config_userconfig || homeRc);
const userRc = read(userconfig);
const leakedEnv = Object.entries(process.env)
  .filter(([, v]) => v && v.includes(CI_TOKEN))
  .map(([k]) => k);

console.log(`mode=${mode} userconfig=${userconfig}`);

switch (mode) {
  case "install-github-packages":
    expect(userconfig === homeRc,
      `npm reads ${userconfig}, not ~/.npmrc: a setup-node registry-url npmrc shadows the GitHub Packages credential`);
    expect(read(homeRc).includes(GITHUB_PACKAGES_AUTH),
      "~/.npmrc lacks the CI_TOKEN credential for npm.pkg.github.com");
    break;
  case "install-default":
    expect(userconfig !== homeRc,
      "npm reads ~/.npmrc: setup-node's registry npmrc is no longer in force for a default caller");
    expect(userRc.includes(PUBLIC_NPM_AUTH), `${userconfig} lacks setup-node's public npm auth line`);
    expect(!userRc.includes(CI_TOKEN) && !read(homeRc).includes(CI_TOKEN),
      "CI_TOKEN is in an npmrc although npm-github-packages is off");
    expect(leakedEnv.length === 0, `CI_TOKEN is in the environment: ${leakedEnv.join(", ")}`);
    break;
  case "publish":
    expect(userconfig !== homeRc, "npm publish reads ~/.npmrc, not setup-node's public npm npmrc");
    expect(userRc.includes(PUBLIC_NPM_AUTH), `${userconfig} lacks setup-node's public npm auth line`);
    expect(!userRc.includes(CI_TOKEN), `CI_TOKEN is in the npmrc npm publish reads (${userconfig})`);
    expect(!read(homeRc).includes(CI_TOKEN), "CI_TOKEN is still in ~/.npmrc at publish time");
    expect(leakedEnv.length === 0, `CI_TOKEN is in npm publish's environment: ${leakedEnv.join(", ")}`);
    expect(process.env.NODE_AUTH_TOKEN === NPM_TOKEN, "NODE_AUTH_TOKEN is not NPM_TOKEN at publish time");
    expect(npm("config", "get", "registry") === "https://registry.npmjs.org/",
      "npm publish's registry is not https://registry.npmjs.org/");
    break;
  default:
    failures.push(`unknown mode '${mode}' (want install-github-packages, install-default or publish)`);
}

if (failures.length) {
  for (const f of failures) console.log(`::error::${f}`);
  process.exit(1);
}
console.log(`PASS: ${mode}`);
