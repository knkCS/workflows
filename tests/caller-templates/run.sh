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
#   5. the release `main` template gates release-please on the merge check and
#      each publish job on a release-please output, and its merge check passes
#      the same go-version-file, working-directory and runs-on as the PR suite,
#      so the caches the merge check saves on `main` are the ones PRs restore.
#
# Requires: python3 with PyYAML.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

python3 -c 'import yaml' 2>/dev/null || { echo "FATAL: python3 lacks PyYAML" >&2; exit 2; }

python3 - "$REPO_ROOT" <<'PY'
import pathlib, re, sys
import yaml

root = pathlib.Path(sys.argv[1])
tpl_dir = root / "templates"
wf_dir = root / ".github" / "workflows"

PR_SUITE = "pr.yml"
RELEASE_MAIN = "release/main.yml"
REQUIRED = {PR_SUITE, RELEASE_MAIN, "commitlint.yml"}
TEST_ONLY_INPUTS = {"test-changed-files", "test-soft-fail"}
CALL = re.compile(r"^knkcs/workflows/\.github/workflows/([A-Za-z0-9_.-]+\.ya?ml)@(.+)$", re.I)
CANCEL = "${{ github.event_name == 'pull_request' }}"
CACHE_KEYS = ("go-version-file", "working-directory", "runs-on")

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

def ancestors(jobs, name, seen=None):
    seen = set() if seen is None else seen
    needs = jobs.get(name, {}).get("needs") or []
    for n in [needs] if isinstance(needs, str) else needs:
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

def calls(rel, workflow):
    return {j: s for j, s in (docs.get(rel, {}).get("jobs") or {}).items()
            if CALL.match(str(s.get("uses", ""))) and CALL.match(s["uses"]).group(1) == workflow}

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
    gates = [j for j, s in calls(rel, "go-service-ci.yml").items()
             if (s.get("with") or {}).get("mode") == "merge-check"]
    if len(gates) != 1:
        fail(where, "must call go-service-ci.yml with mode: merge-check exactly once")
        continue
    gate = gates[0]
    for job in jobs:
        if job != gate and gate not in ancestors(jobs, job):
            fail(where, f"job '{job}' does not depend on the merge check '{gate}'")
    # 5. The same cache-relevant inputs as the PR suite.
    for pj, pspec in pr_jobs.items():
        pw, mw = pspec.get("with") or {}, jobs[gate].get("with") or {}
        for key in CACHE_KEYS:
            if pw.get(key) != mw.get(key):
                fail(where, f"merge check passes {key}={mw.get(key)!r}, PR suite {pw.get(key)!r}: cache keys would differ")

# 5. The release model: release-please behind the merge check, publishing behind release-please.
if RELEASE_MAIN in docs:
    where = f"templates/{RELEASE_MAIN}"
    jobs = docs[RELEASE_MAIN].get("jobs") or {}
    rp = list(calls(RELEASE_MAIN, "release-please.yml"))
    gate = [j for j, s in calls(RELEASE_MAIN, "go-service-ci.yml").items()
            if (s.get("with") or {}).get("mode") == "merge-check"]
    if len(rp) != 1:
        fail(where, "must call release-please.yml exactly once")
    elif gate:
        needs = jobs[rp[0]].get("needs") or []
        if gate[0] not in ([needs] if isinstance(needs, str) else needs):
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

for rel in docs:
    print(f"  templates/{rel}")
if failures:
    print("\nFAIL", *failures, sep="\n  ")
    sys.exit(1)
print("\nPASS: every caller template pins @v1, calls only declared inputs, cancels on PRs only and gates on the merge check")
PY
