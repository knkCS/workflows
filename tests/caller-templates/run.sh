#!/usr/bin/env bash
#
# Self-test for the caller templates under templates/. actionlint (also run by
# self-test.yml over templates/) checks each template is a valid workflow, but
# it cannot see into a remote reusable workflow: a template calling
# `knkcs/workflows/...@v1` with a misspelt or removed input would lint clean
# and only fail in the caller that copied it. This proves, for every template:
#
#   1. every call to this repo is pinned `@v1` (ADR 0003) and names a workflow
#      that exists here, with only inputs and secrets it declares, every
#      required one passed, and none of the test-only inputs;
#   2. its concurrency group is per workflow and per PR or ref, and it cancels
#      a superseded run only on `pull_request` — so `main` queues;
#   3. every job that is not a reusable-workflow call declares timeout-minutes
#      (a `uses:` job cannot — the called workflow's jobs carry theirs);
#   4. the PR suite runs go-service-ci in `pr-suite` mode on `pull_request`
#      only, and a `main` template runs the merge check on `push: main` only,
#      with every other job depending on it, directly or through another job;
#   5. a `main` template's merge check sees the same go-version-file,
#      working-directory and runs-on as the PR suite, so the caches it saves on
#      `main` are the ones PRs restore, the same layout inputs, so it checks
#      the same tree, and the same npm inputs (npm-github-packages,
#      node-ci-flags), so its `npm ci` installs what the PR suite's does;
#   6. the release `main` template gates release-please on the merge check and
#      each publish job on a release-please output;
#   7. every publish job in the release `main` template builds the release
#      tag — `ref:` set to release-please's `tag_name` output — never the
#      triggering commit, which a replaced pending run can make a later one;
#   8. a publish-ui call with `npm-github-packages: true` passes CI_TOKEN (the
#      credential its `npm ci` needs), and one without it passes no CI_TOKEN
#      (publish-ui has no other use for the token, so passing it would only
#      hand it to a job that ignores it). `dry-run` is test-only.
#
# TEMPLATES_DIR overrides templates/ — e.g. a directory holding a caller's own
# main.yml as release/main.yml, to check that caller against these workflows.
#
# Requires: python3 with PyYAML.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

python3 -c 'import yaml' 2>/dev/null || { echo "FATAL: python3 lacks PyYAML" >&2; exit 2; }

python3 - "$REPO_ROOT" "${TEMPLATES_DIR:-$REPO_ROOT/templates}" <<'PY'
import pathlib, re, sys
import yaml

root = pathlib.Path(sys.argv[1])
tpl_dir = pathlib.Path(sys.argv[2])
wf_dir = root / ".github" / "workflows"

PR_SUITE = "pr.yml"
RELEASE_MAIN = "release/main.yml"
REQUIRED = {PR_SUITE, RELEASE_MAIN, "commitlint.yml"}
TEST_ONLY_INPUTS = {"test-changed-files", "test-soft-fail", "dry-run"}
CALL = re.compile(r"^knkcs/workflows/\.github/workflows/([A-Za-z0-9_.-]+\.ya?ml)@(.+)$", re.I)
CANCEL = "${{ github.event_name == 'pull_request' }}"
CACHE_KEYS = ("go-version-file", "working-directory", "runs-on")
LAYOUT_KEYS = ("helm-chart", "ui-package", "embed-frontend", "frontend-build",
               "check-ent-drift", "check-gofmt")
NPM_KEYS = ("npm-github-packages", "node-ci-flags")

failures = []
def fail(where, msg):
    failures.append(f"{where}: {msg}")

def trigger(doc):
    # PyYAML reads the bare key `on` as boolean True.
    on = doc.get("on", doc.get(True))
    if isinstance(on, str):
        return {on: None}
    if isinstance(on, list):
        return {k: None for k in on}
    return on or {}

def called(workflow):
    doc = yaml.safe_load((wf_dir / workflow).read_text())
    call = trigger(doc).get("workflow_call") or {}
    return call.get("inputs") or {}, call.get("secrets") or {}

def input_value(spec, key, defaults):
    # The value a call passes for one input, as the called workflow sees it:
    # an omitted input is its default. Compared literally (an expression is
    # its string), so `true` and `${{ true }}` differ.
    passed = spec.get("with") or {}
    return passed.get(key, defaults.get(key))

def needs_of(spec):
    needs = spec.get("needs") or []
    return [needs] if isinstance(needs, str) else needs

def ancestors(jobs, name, seen=None):
    seen = set() if seen is None else seen
    for n in needs_of(jobs.get(name, {})):
        if n not in seen:
            seen.add(n)
            ancestors(jobs, n, seen)
    return seen

templates = {p.relative_to(tpl_dir).as_posix(): p
             for p in sorted(tpl_dir.rglob("*")) if p.suffix in (".yml", ".yaml")}
for want in sorted(REQUIRED - set(templates)):
    fail(f"templates/{want}", "missing")

docs = {}
for rel, path in templates.items():
    where = f"templates/{rel}"
    doc = docs[rel] = yaml.safe_load(path.read_text()) or {}
    jobs = doc.get("jobs") or {}
    if not jobs:
        fail(where, "has no jobs")

    # 2. Concurrency: per workflow + PR/ref; cancel on PRs only.
    conc = doc.get("concurrency")
    if not isinstance(conc, dict):
        fail(where, "has no concurrency block")
    else:
        group = str(conc.get("group", ""))
        if "github.workflow" not in group or "github.ref" not in group:
            fail(where, f"concurrency group {group!r} is not per workflow and per PR/ref")
        if str(conc.get("cancel-in-progress")).strip() != CANCEL:
            fail(where, f"cancel-in-progress must be {CANCEL} (cancel on PRs, queue on main)")

    for job, spec in jobs.items():
        uses = spec.get("uses")
        # 3. Timeouts on every job that runs steps itself.
        if uses is None:
            if "timeout-minutes" not in spec:
                fail(where, f"job '{job}' has no timeout-minutes")
            for step in spec.get("steps") or []:
                ref = str(step.get("uses", ""))
                if ref.lower().startswith("knkcs/workflows/") and not ref.endswith("@v1"):
                    fail(where, f"job '{job}' uses {ref}: pin @v1 (ADR 0003)")
            continue
        # 1. Calls: @v1, to a workflow that exists, with declared inputs only.
        m = CALL.match(str(uses))
        if not m:
            fail(where, f"job '{job}' calls {uses}, not a knkcs/workflows reusable workflow")
            continue
        workflow, ref = m.groups()
        if ref != "v1":
            fail(where, f"job '{job}' pins @{ref}: pin @v1 (ADR 0003)")
        if not (wf_dir / workflow).is_file():
            fail(where, f"job '{job}' calls {workflow}, which this repo does not have")
            continue
        inputs, secrets = called(workflow)
        passed = spec.get("with") or {}
        for name in passed:
            if name in TEST_ONLY_INPUTS:
                fail(where, f"job '{job}' sets the test-only input '{name}'")
            elif name not in inputs:
                fail(where, f"job '{job}' passes '{name}', which {workflow} does not declare")
        for name, decl in inputs.items():
            if (decl or {}).get("required") and name not in passed:
                fail(where, f"job '{job}' omits {workflow}'s required input '{name}'")
        given = spec.get("secrets") or {}
        if given == "inherit":
            fail(where, f"job '{job}' uses `secrets: inherit`: pass each secret by name")
            given = {}
        for name in given:
            if name not in secrets:
                fail(where, f"job '{job}' passes secret '{name}', which {workflow} does not declare")
        for name, decl in secrets.items():
            if (decl or {}).get("required") and name not in given:
                fail(where, f"job '{job}' omits {workflow}'s required secret '{name}'")
        # 8. publish-ui's CI_TOKEN goes with npm-github-packages, and only with it.
        if workflow == "publish-ui.yml":
            gh_packages = passed.get("npm-github-packages") is True
            if gh_packages and "CI_TOKEN" not in given:
                fail(where, f"job '{job}' sets npm-github-packages but passes no CI_TOKEN: its `npm ci` cannot authenticate")
            if "CI_TOKEN" in given and not gh_packages:
                fail(where, f"job '{job}' passes CI_TOKEN without npm-github-packages: true, which is all publish-ui uses it for")

def calls(rel, workflow):
    matches = {j: CALL.match(str(s.get("uses", ""))) for j, s in (docs.get(rel, {}).get("jobs") or {}).items()}
    return {j: docs[rel]["jobs"][j] for j, m in matches.items() if m and m.group(1) == workflow}

def merge_checks(rel):
    return [j for j, s in calls(rel, "go-service-ci.yml").items()
            if (s.get("with") or {}).get("mode") == "merge-check"]

# 4a. The PR suite.
pr_jobs = {}
if PR_SUITE in docs:
    where = f"templates/{PR_SUITE}"
    if set(trigger(docs[PR_SUITE])) != {"pull_request"}:
        fail(where, "must trigger on pull_request only (push: main runs the merge check)")
    pr_jobs = calls(PR_SUITE, "go-service-ci.yml")
    if len(pr_jobs) != 1:
        fail(where, "must call go-service-ci.yml exactly once")
    for job, spec in pr_jobs.items():
        if (spec.get("with") or {}).get("mode", "pr-suite") != "pr-suite":
            fail(where, f"job '{job}' must run go-service-ci in pr-suite mode")

# 4b. Every `main` template: merge check first, everything else behind it.
for rel in docs:
    if pathlib.PurePosixPath(rel).name != "main.yml":
        continue
    where = f"templates/{rel}"
    on = trigger(docs[rel])
    branches = (on.get("push") or {}).get("branches") if isinstance(on.get("push"), dict) else None
    if set(on) != {"push"} or branches != ["main"]:
        fail(where, "must trigger on push to main only")
    jobs = docs[rel].get("jobs") or {}
    gates = merge_checks(rel)
    if len(gates) != 1:
        fail(where, "must call go-service-ci.yml with mode: merge-check exactly once")
        continue
    gate = gates[0]
    for job in jobs:
        if job != gate and gate not in ancestors(jobs, job):
            fail(where, f"job '{job}' does not depend on the merge check '{gate}'")
    # 5. The same cache, layout and npm inputs as the PR suite, compared as
    # the workflow sees them (an omitted input is its default).
    defaults = {k: (v or {}).get("default") for k, v in called("go-service-ci.yml")[0].items()}
    for pspec in pr_jobs.values():
        for key in CACHE_KEYS + LAYOUT_KEYS + NPM_KEYS:
            pv, mv = input_value(pspec, key, defaults), input_value(jobs[gate], key, defaults)
            if pv != mv:
                why = ("cache keys would differ" if key in CACHE_KEYS
                       else "its `npm ci` would not install what the PR suite's does" if key in NPM_KEYS
                       else "it would check a different tree")
                fail(where, f"merge check passes {key}={mv!r}, PR suite {pv!r}: {why}")

# 6. The release model: release-please behind the merge check, publishing behind release-please.
if RELEASE_MAIN in docs:
    where = f"templates/{RELEASE_MAIN}"
    jobs = docs[RELEASE_MAIN].get("jobs") or {}
    rp = list(calls(RELEASE_MAIN, "release-please.yml"))
    gate = merge_checks(RELEASE_MAIN)
    if len(rp) != 1:
        fail(where, "must call release-please.yml exactly once")
    elif gate:
        if gate[0] not in needs_of(jobs[rp[0]]):
            fail(where, f"release-please must `needs:` the merge check '{gate[0]}' directly")
        for wf in ("publish-image-chart.yml", "publish-ui.yml"):
            pubs = calls(RELEASE_MAIN, wf)
            if not pubs:
                fail(where, f"must call {wf}")
            for job, spec in pubs.items():
                if rp[0] not in ancestors(jobs, job):
                    fail(where, f"job '{job}' does not depend on release-please")
                if f"needs.{rp[0]}.outputs" not in str(spec.get("if", "")):
                    fail(where, f"job '{job}' is not gated by an `if:` on release-please's outputs")
                # 7. Build the release tag, never github.sha: main queues, a
                # newer push replaces a pending run, and the tag would then
                # point at a different commit from the one being built.
                ref = str((spec.get("with") or {}).get("ref", ""))
                if not ref:
                    fail(where, f"job '{job}' passes no `ref`: it would build github.sha, not the release tag")
                elif f"needs.{rp[0]}.outputs" not in ref or "tag_name" not in ref:
                    fail(where, f"job '{job}' passes ref={ref!r}: it must be release-please's tag_name output")

for rel in docs:
    print(f"  templates/{rel}")
if failures:
    print("\nFAIL", *failures, sep="\n  ")
    sys.exit(1)
print("\nPASS: every caller template pins @v1, calls only declared inputs, cancels on PRs only, gates on the merge check and publishes the release tag")
PY
