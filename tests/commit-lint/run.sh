#!/usr/bin/env bash
#
# Fixture self-test for scripts/commit-lint.sh, the conventional-commit lint
# go-service-ci's `changes` job runs in `pr-suite` mode. Run by self-test.yml.
#
# The lint is what keeps release-please's version bumps honest, so each case
# pins one thing it must accept or refuse: conforming commits (breaking and
# scoped ones included) pass, a non-conventional one fails and is named, a
# merge commit is ignored, an empty list passes, and input it cannot read is
# an error rather than a pass.
#
# Installs the pinned commitlint from npm into a temporary directory, unless
# COMMITLINT_DIR names one that already holds it (a local re-run).
#
# Requires: bash, jq, node + npm.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LINT="$REPO_ROOT/scripts/commit-lint.sh"

command -v jq >/dev/null || { echo "FATAL: jq not on PATH" >&2; exit 2; }
command -v npm >/dev/null || { echo "FATAL: npm not on PATH" >&2; exit 2; }

export COMMITLINT_DIR="${COMMITLINT_DIR:-$(mktemp -d)}"

failures=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

# lint NAME WANT_EXIT JSON [MUST_MENTION]
# Runs the lint on JSON (the commits, as the script reads them on stdin) and
# checks its exit code; MUST_MENTION, when given, must appear in its output
# (the commit the failure names).
lint() {
  local name=$1 want=$2 json=$3 mention=${4:-} out code=0
  out=$(printf '%s' "$json" | bash "$LINT" 2>&1) || code=$?
  if [ "$code" != "$want" ]; then
    fail "$name: want exit $want, got $code"; printf '%s\n' "$out" | sed 's/^/        /'; return
  fi
  if [ -n "$mention" ] && ! grep -qF -- "$mention" <<<"$out"; then
    fail "$name: output does not mention '$mention'"; printf '%s\n' "$out" | sed 's/^/        /'; return
  fi
  pass "$name -> exit $code"
}

echo "commit lint:"
lint "conforming commits pass" 0 \
  '[{"sha":"aaa1111","message":"feat: add the lint"},{"sha":"bbb2222","message":"fix(api): handle an empty list\n\nWith a body."}]'
lint "a breaking change passes" 0 \
  '[{"sha":"ccc3333","message":"feat(api)!: drop v1\n\nBREAKING CHANGE: v1 is gone"}]'
lint "plain strings are commits too" 0 \
  '["docs: explain the lint","chore(deps): bump commitlint"]'
lint "an empty list passes" 0 '[]'
lint "a merge commit is ignored" 0 \
  '[{"sha":"ddd4444","message":"Merge branch '\''main'\'' into feat/x"},{"sha":"eee5555","message":"Merge pull request #1 from knkCS/x\n\nfeat: x"}]'
lint "a non-conventional commit fails and is named" 1 \
  '[{"sha":"fff6666","message":"feat: fine"},{"sha":"9990000","message":"added some stuff"}]' 9990000
lint "an unknown type fails" 1 '[{"sha":"1234567","message":"feature: add x"}]' 1234567
lint "a sentence-case subject fails" 1 '[{"sha":"7654321","message":"feat: Add x"}]' 7654321
lint "every bad commit is reported, not only the first" 1 \
  '[{"sha":"a1a1a1a","message":"wip"},{"sha":"b2b2b2b","message":"also wip"}]' b2b2b2b
lint "input that is not JSON is an error" 2 'feat: not json'
lint "input that is not a list is an error" 2 '{"message":"feat: x"}'

if [ "$failures" -gt 0 ]; then
  printf '\nFAIL: %d case(s)\n' "$failures"; exit 1
fi
printf '\nPASS: the commit lint accepts conventional commits and refuses the rest\n'
