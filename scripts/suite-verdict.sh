#!/usr/bin/env bash
#
# Suite verdict: the one result a PR suite reports.
#
#   suite-verdict.sh < needs.json
#
# Reads the `needs` context of go-service-ci's `ci-ok` job as JSON on stdin
# (`${{ toJSON(needs) }}`: {"<job>": {"result": "...", "outputs": {...}}, ...})
# and exits 0 only when every job's result is `success` or `skipped`.
#
# `skipped` is green because a job skipped by change detection (a docs-only PR
# skipping the Go suite) is the design working. It is NOT a way to hide a
# broken suite: a job skipped because a job it needs failed or was cancelled
# sits beside that failure in the same context, and the failure turns the
# verdict red. `failure`, `cancelled` and any result this script does not know
# are red — an unknown result must never read as a pass.
#
# Requires: jq (preinstalled on GitHub-hosted runners).
set -euo pipefail

needs=$(cat)
if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$needs"; then
  echo "::error::suite verdict: the needs context is not a JSON object"
  exit 1
fi

jq -r 'to_entries[] | "\(.key): \(.value.result)"' <<<"$needs"

bad=$(jq -r 'to_entries[] | select(.value.result != "success" and .value.result != "skipped") | .key' <<<"$needs")
if [ -n "$bad" ]; then
  while IFS= read -r job; do
    echo "::error::suite verdict: job '$job' did not pass"
  done <<<"$bad"
  exit 1
fi
echo "suite verdict: green"
