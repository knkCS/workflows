#!/usr/bin/env bash
#
# Self-test for job timeouts. No job may run to GitHub's 6-hour limit again —
# in September 2026 seven hung image builds did exactly that and burned ~2,500
# minutes. This proves, for every workflow in .github/workflows/:
#
#   1. every job declares `timeout-minutes` (a new job without one fails here);
#   2. each shared workflow's jobs resolve to the agreed defaults — 40 for Go
#      tests (above go-service-ci's 30m `test-timeout`), 30 per image build leg,
#      15 for UI, 10 for everything else;
#   3. the jobs where a slow but healthy run is plausible take their timeout
#      from a `number` input, so a caller can raise it; the rest are fixed.
#
# actionlint (also run by self-test.yml) checks the expressions are valid; it
# does not check that a timeout is present, which is what this adds.
#
# Requires: python3 with PyYAML.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

python3 -c 'import yaml' 2>/dev/null || { echo "FATAL: python3 lacks PyYAML" >&2; exit 2; }

python3 - "$REPO_ROOT/.github/workflows" <<'PY'
import pathlib, re, sys
import yaml

wf_dir = pathlib.Path(sys.argv[1])

# (workflow, job) -> (default minutes, overriding input or None when fixed)
EXPECTED = {
    ("go-service-ci.yml", "backend"):              (10, None),
    ("go-service-ci.yml", "test-testcontainers"):  (40, "test-timeout-minutes"),
    ("go-service-ci.yml", "test-services"):        (40, "test-timeout-minutes"),
    ("go-service-ci.yml", "ui"):                   (15, "ui-timeout-minutes"),
    ("go-service-ci.yml", "helm"):                 (10, None),
    ("publish-image-chart.yml", "build"):          (30, "build-timeout-minutes"),
    ("publish-image-chart.yml", "merge"):          (10, None),
    ("publish-ui.yml", "publish"):                 (15, "ui-timeout-minutes"),
    ("commitlint.yml", "commitlint"):              (10, None),
    ("release-please.yml", "release-please"):      (10, None),
    ("argocd-rendering-check.yml", "render"):      (10, "render-timeout-minutes"),
}
INPUT_REF = re.compile(r"^\$\{\{\s*inputs\.([A-Za-z0-9_-]+)\s*\}\}$")

failures = []
seen = set()
for path in sorted(wf_dir.glob("*.yml")):
    doc = yaml.safe_load(path.read_text())
    # PyYAML reads the bare key `on` as boolean True.
    trigger = doc.get("on", doc.get(True)) or {}
    inputs = (trigger.get("workflow_call") or {}).get("inputs") or {} if isinstance(trigger, dict) else {}
    for job, spec in (doc.get("jobs") or {}).items():
        key = (path.name, job)
        seen.add(key)
        if "timeout-minutes" not in spec:
            failures.append(f"{path.name}: job '{job}' has no timeout-minutes")
            continue
        raw = spec["timeout-minutes"]
        m = INPUT_REF.match(str(raw).strip())
        if m:
            name = m.group(1)
            decl = inputs.get(name)
            if decl is None:
                failures.append(f"{path.name}: job '{job}' timeout uses undeclared input '{name}'")
                continue
            if decl.get("type") != "number":
                failures.append(f"{path.name}: input '{name}' must be type number")
            resolved, via = decl.get("default"), name
        else:
            resolved, via = raw, None
        if key in EXPECTED:
            want, want_via = EXPECTED[key]
            if resolved != want:
                failures.append(f"{path.name}: job '{job}' timeout defaults to {resolved!r}, want {want}")
            if via != want_via:
                failures.append(f"{path.name}: job '{job}' timeout comes from {via or 'a literal'}, want {want_via or 'a literal'}")
        print(f"  {path.name:28} {job:22} {resolved!s:>3} min{'  (input ' + via + ')' if via else ''}")

for key in sorted(set(EXPECTED) - seen):
    failures.append(f"{key[0]}: expected job '{key[1]}' not found")

if failures:
    print("\nFAIL", *failures, sep="\n  ")
    sys.exit(1)
print("\nPASS: every job declares timeout-minutes with the agreed defaults")
PY
