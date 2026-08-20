#!/usr/bin/env bash
#
# Self-test for scripts/argocd-rendering-check.py — the engine behind the
# argocd-rendering-check reusable workflow. Proves the check GREEN on a correct
# deploy-repo layout and RED on a broken one, against committed fixtures, with
# no network beyond localhost:
#
#   1. good fixture           -> exit 0; environment overrides land in the output
#   2. broken: missing values -> exit non-zero, naming the missing file
#   3. same fixture, but the broken environment is skipped via --skip-env -> exit 0
#   4. broken: schema typo    -> exit non-zero from kubeconform on the rendered output
#
# The fixture mirrors knkcms/deploy's three source shapes. The service-repo git
# source is satisfied by building a throwaway git repo and mapping the fixture's
# repoURL onto it with git's own url.insteadOf (via GIT_CONFIG_* env vars — the
# same mechanism the workflow uses to inject CI_TOKEN, so the clone path under
# test is the one CI takes). The upstream-Helm-repository source is served by a
# localhost `python3 -m http.server`. The OCI registry spelling (schemeless
# repoURL) cannot be served that way and is covered by runs against a real
# deploy repo, not here.
#
# Requires: python3 (with PyYAML), git, helm, kubeconform, curl.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
RENDERER="$REPO_ROOT/scripts/argocd-rendering-check.py"
FIXTURES="$HERE/fixtures"
# The port is baked into fixtures/good/argocd/applicationsets/infrastructure.yaml.
PORT=8879

for tool in python3 git helm kubeconform curl; do
  command -v "$tool" >/dev/null || { echo "FATAL: $tool not on PATH" >&2; exit 2; }
done
python3 -c 'import yaml' 2>/dev/null || { echo "FATAL: python3 lacks PyYAML" >&2; exit 2; }

TMP="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- fixture backends -------------------------------------------------------

# Throwaway "service repo" for the git chart source.
SVC="$TMP/demo-svc"
mkdir -p "$SVC/charts"
cp -R "$FIXTURES/demo-chart" "$SVC/charts/demo"
git -C "$SVC" init --quiet --initial-branch=main
git -C "$SVC" add -A
git -C "$SVC" -c user.email=fixture@invalid -c user.name=fixture commit --quiet -m "demo chart"
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="url.file://$SVC.insteadOf"
export GIT_CONFIG_VALUE_0="https://github.com/knkcs-fixtures/demo.git"

# Localhost Helm repository for the upstream-chart source.
HTDOCS="$TMP/htdocs"
mkdir -p "$HTDOCS"
helm package "$FIXTURES/demo-chart" -d "$HTDOCS" >/dev/null
helm repo index "$HTDOCS" --url "http://127.0.0.1:$PORT"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$HTDOCS" >/dev/null 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
  curl -sf "http://127.0.0.1:$PORT/index.yaml" >/dev/null 2>&1 && break
  kill -0 "$SERVER_PID" 2>/dev/null || { echo "FATAL: fixture Helm repo died — is port $PORT taken?" >&2; exit 2; }
  sleep 0.1
done

# --- assertions -------------------------------------------------------------

failures=0
before=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
begin() { before=$failures; }
pass() { if [ "$failures" -eq "$before" ]; then echo "ok: $*"; fi; }

# 1. The good fixture renders and validates green, and the per-environment
#    values actually land: production overrides replicas to 2, staging stays 1.
out="$TMP/good-out"
begin
if log=$(python3 "$RENDERER" \
    --repo-root "$FIXTURES/good" \
    --repo-url https://github.com/knkcs-fixtures/deploy.git \
    --output-dir "$out" 2>&1); then
  echo "$log" | grep -q "rendered 6 application" \
    || fail "good: expected 6 rendered applications; log: $log"
  grep -q '^  replicas: 1$' "$out/fixture-demo-staging.yaml" \
    || fail "good: staging values did not land (want replicas: 1)"
  grep -q '^  replicas: 2$' "$out/fixture-demo-production.yaml" \
    || fail "good: production override did not land (want replicas: 2)"
  grep -q 'fixture-message: "infra-base"' "$out/fixture-demo-infra-staging.yaml" \
    || fail "good: helm-repo chart did not read the deploy repo's values"
  grep -q 'image: nginx:relative-tag' "$out/fixture-demo-local-staging.yaml" \
    || fail "good: chart-relative value file did not resolve against the source's path"
  pass "good fixture renders and validates"
else
  fail "good: expected exit 0, got $?; log: $log"
fi

# 2. A missing value file fails the check — asserted RED by inverting the exit
#    code — and the failure names the file a developer has to create.
begin
if log=$(python3 "$RENDERER" \
    --repo-root "$FIXTURES/broken" \
    --repo-url https://github.com/knkcs-fixtures/deploy.git \
    --argocd-dir argocd-missing-values \
    --output-dir "$TMP/broken-missing-out" 2>&1); then
  fail "broken/missing-values: expected a non-zero exit, got success; log: $log"
else
  echo "$log" | grep -q "missing value file" \
    || fail "broken/missing-values: error does not say 'missing value file'; log: $log"
  echo "$log" | grep -q 'environments/production/infrastructure/demo-local-values.yaml' \
    || fail "broken/missing-values: error does not name the missing file; log: $log"
  pass "missing value file fails the check, naming the file"
fi

# 3. The same fixture goes green when the broken environment is skipped — the
#    unwired-environment knob — and the wired environment still renders.
begin
if log=$(python3 "$RENDERER" \
    --repo-root "$FIXTURES/broken" \
    --repo-url https://github.com/knkcs-fixtures/deploy.git \
    --argocd-dir argocd-missing-values \
    --skip-env production \
    --output-dir "$TMP/broken-skip-out" 2>&1); then
  echo "$log" | grep -q "rendered 1 application" \
    || fail "skip-env: expected the staging application to still render; log: $log"
  echo "$log" | grep -q "skipped 1 by environment filter" \
    || fail "skip-env: expected 1 skipped application; log: $log"
  pass "--skip-env skips the unwired environment"
else
  fail "skip-env: expected exit 0 with production skipped, got $?; log: $log"
fi

# 4. A values typo that only breaks the RENDERED manifest (replicas: "three")
#    fails the check via kubeconform — asserted RED by inverting the exit code.
begin
if log=$(python3 "$RENDERER" \
    --repo-root "$FIXTURES/broken" \
    --repo-url https://github.com/knkcs-fixtures/deploy.git \
    --argocd-dir argocd-bad-schema \
    --output-dir "$TMP/broken-schema-out" 2>&1); then
  fail "broken/bad-schema: expected a non-zero exit, got success; log: $log"
else
  echo "$log" | grep -qi "invalid" \
    || fail "broken/bad-schema: expected kubeconform to report an invalid manifest; log: $log"
  pass "schema-invalid rendered output fails the check"
fi

# 5. A source path that references a directory the repo does not have — the
#    "bad reference" defect class — fails with an error naming the path, not a
#    traceback. Asserted RED by inverting the exit code.
begin
if log=$(python3 "$RENDERER" \
    --repo-root "$FIXTURES/broken" \
    --repo-url https://github.com/knkcs-fixtures/deploy.git \
    --argocd-dir argocd-bad-path \
    --output-dir "$TMP/broken-path-out" 2>&1); then
  fail "broken/bad-path: expected a non-zero exit, got success; log: $log"
else
  echo "$log" | grep -q "charts/nope' does not exist" \
    || fail "broken/bad-path: error does not name the bad path; log: $log"
  if echo "$log" | grep -q "Traceback"; then
    fail "broken/bad-path: died with a traceback instead of a named error; log: $log"
  fi
  pass "a bad source path fails the check, naming the path"
fi

# --- verdict ----------------------------------------------------------------

if [ "$failures" -gt 0 ]; then
  echo "self-test: $failures failure(s)" >&2
  exit 1
fi
echo "self-test: all checks passed"
