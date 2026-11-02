#!/usr/bin/env bash
#
# Conventional-commit lint of a pull request's commits.
#
#   commit-lint.sh < commits.json
#
# Reads a JSON array on stdin, each element a commit — {"sha": ..., "message":
# ...} or a bare message string — and lints every message with commitlint and
# @commitlint/config-conventional, the rule set the reusable commitlint.yml
# applies (wagoid/commitlint-github-action v6, commitlint 19). Exits 0 when
# every commit conforms (warnings do not fail, as there), 1 when any does not,
# naming each one with an ::error:: annotation, and 2 on input it cannot read.
# commitlint's own ignores apply: merge, revert and fixup commits are skipped.
#
# go-service-ci's `changes` job runs this in `pr-suite` mode, so a bad commit
# message turns the suite verdict red without a job of its own (CONTEXT.md,
# "PR suite"). The job fetches the commits from the compare API, which needs
# only `contents: read`. tests/commit-lint/run.sh is its fixture self-test.
#
# commitlint is installed from npm, at the pinned versions below, into
# COMMITLINT_DIR (default: a fresh temporary directory); an install already
# there is reused. Requires: bash, jq, node + npm.
set -euo pipefail

COMMITLINT_VERSION=19.8.1

input=$(cat)
if ! n=$(jq -e 'if type == "array" then length else error("not an array") end' <<<"$input" 2>/dev/null); then
  echo "::error::commit-lint: stdin is not a JSON array of commits" >&2
  exit 2
fi
if [ "$n" -eq 0 ]; then
  echo "no commits to lint"
  exit 0
fi

dir="${COMMITLINT_DIR:-$(mktemp -d)}"
bin="$dir/node_modules/.bin/commitlint"
if [ ! -x "$bin" ]; then
  npm install --prefix "$dir" --no-save --no-audit --no-fund --loglevel=error \
    "@commitlint/cli@$COMMITLINT_VERSION" "@commitlint/config-conventional@$COMMITLINT_VERSION" >&2
fi
# An ESM config next to the install, so `extends` resolves from its node_modules.
config="$dir/commitlint.config.mjs"
echo 'export default { extends: ["@commitlint/config-conventional"] };' >"$config"

bad=0
for ((i = 0; i < n; i++)); do
  sha=$(jq -r ".[$i] | if type == \"object\" then (.sha // \"\") else \"\" end" <<<"$input")
  message=$(jq -r ".[$i] | if type == \"object\" then (.message // \"\") else . end" <<<"$input")
  subject=${message%%$'\n'*}
  label="${sha:0:7}${sha:+ }$subject"
  if out=$(printf '%s\n' "$message" | "$bin" --config "$config" 2>&1); then
    printf 'ok    %s\n' "$label"
  else
    bad=$((bad + 1))
    printf 'FAIL  %s\n%s\n' "$label" "$out"
    echo "::error::commit ${sha:0:7}${sha:+ }is not a conventional commit: $subject"
  fi
done

if [ "$bad" -gt 0 ]; then
  echo "::error::$bad of $n commit(s) are not conventional commits — reword them (e.g. git rebase -i) and force-push; see https://www.conventionalcommits.org"
  exit 1
fi
echo "all $n commit(s) are conventional commits"
