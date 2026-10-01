#!/usr/bin/env bash
#
# The configure-private-modules action: lets `go` fetch private modules of the
# knkCS and knkcms orgs (and any extra patterns) with CI_TOKEN.
#
#   - GOPRIVATE (written to $GITHUB_ENV for the job's later steps) lists the
#     module path patterns that skip the public proxy and checksum database —
#     GONOPROXY and GONOSUMDB default to it. Go matches the patterns
#     case-sensitively against module paths, which for both orgs are lowercase
#     (github.com/knkcs/..., github.com/knkcms/...), so the defaults are too.
#   - One git url.insteadOf puts CI_TOKEN into every https://github.com/ URL,
#     whatever the org: the token, not the rewrite, decides what is readable.
#
# Env: CI_TOKEN (the action's `ci-token`), EXTRA_PATTERNS (its
# `extra-patterns`: comma-, space- or newline-separated, appended to the
# default), GITHUB_ENV. Tested by tests/private-modules/run.sh.
set -euo pipefail

goprivate='github.com/knkcs/*,github.com/knkcms/*'
set -f  # the patterns are Go globs, not file names
for pattern in ${EXTRA_PATTERNS//,/ }; do
  goprivate="$goprivate,$pattern"
done

echo "GOPRIVATE=$goprivate" >>"$GITHUB_ENV"
git config --global url."https://${CI_TOKEN}@github.com/".insteadOf "https://github.com/"
