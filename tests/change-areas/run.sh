#!/usr/bin/env bash
#
# Fixture self-test for scripts/change-areas.sh (the change-area classifier
# behind go-service-ci's `changes` job) and scripts/suite-verdict.sh (the
# verdict behind its `ci-ok` job). Run by self-test.yml.
#
# A wrong classifier does not fail loudly in a caller — it silently skips the
# checks a PR needed. So every rule, and above all the conservative one (a file
# in no known area turns on every area), is pinned here by a case.
#
# Requires: bash, jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
CLASSIFY="$REPO_ROOT/scripts/change-areas.sh"
VERDICT="$REPO_ROOT/scripts/suite-verdict.sh"

command -v jq >/dev/null || { echo "FATAL: jq not on PATH" >&2; exit 2; }

failures=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

# areas NAME EXPECTED FILES [DOCS_EXCLUDE]
# EXPECTED is the comma-separated set of areas that must be on, in the order
# docs,go,ui,image ("" = none). FILES is newline-separated.
areas() {
  local name=$1 want=$2 files=$3 exclude=${4-} out got=""
  if ! out=$(printf '%s' "$files" | bash "$CLASSIFY" --docs-exclude "$exclude" 2>/dev/null); then
    fail "$name: classifier exited non-zero"; return
  fi
  local area
  for area in docs go ui image; do
    if grep -qx "$area=true" <<<"$out"; then got="${got:+$got,}$area"
    elif ! grep -qx "$area=false" <<<"$out"; then fail "$name: no '$area=' line in output"; return
    fi
  done
  if [ "$got" = "$want" ]; then pass "$name -> {$got}"
  else fail "$name: want {$want}, got {$got}"
  fi
}

ALL=docs,go,ui,image

echo "change areas:"
areas "docs-only" docs \
'README.md
docs/adr/0004-something.md
CONTEXT.md
CLAUDE.md
.scratch/notes.txt
LICENSE
docs/diagram.png
.github/ISSUE_TEMPLATE/bug.yml
.github/PULL_REQUEST_TEMPLATE.md
internal/service/README.md'
areas "UI-only" ui \
'packages/app-ui/src/App.tsx
web/src/main.ts
package.json
package-lock.json
.npmrc'
areas "Go-only" go \
'internal/service/service.go
cmd/server/main.go
go.mod
go.sum
api/v1/service.proto
migrations/0001_init.sql
.golangci.yml'
areas "*.go under a web dir is Go" go 'web/embed.go'
areas "*.go under docs/ is Go" go 'docs/example/main.go'
areas "Dockerfile-only" image \
'Dockerfile
.dockerignore
docker/entrypoint.sh'
areas "Dockerfile variant in a subdirectory" image 'build/Dockerfile.dev'
areas "Markdown under testdata is not docs" $ALL 'internal/parser/testdata/input.md'
areas "Markdown under fixtures is not docs" $ALL 'tests/fixtures/page.md'
areas "Markdown under __fixtures__ in the UI is UI" ui 'packages/app-ui/src/__fixtures__/story.md'
areas ".claude/ file is every area" $ALL '.claude/settings.json'
areas ".claude/ Markdown is every area" $ALL '.claude/skills/foo/SKILL.md'
areas "release-please manifest only" docs '.release-please-manifest.json'
areas "unknown file is every area" $ALL 'Makefile'
areas "unknown file beside docs is every area" $ALL \
'README.md
charts/app/values.yaml'
areas "a workflow is every area" $ALL '.github/workflows/ci.yml'
areas "docs-exclude match is not docs" $ALL 'design/spec.md' 'design/*'
areas "docs-exclude match still classified" ui 'web/content/page.md' 'web/content/*'
areas "docs-exclude, several patterns" docs \
'README.md
docs/guide.md' \
'design/*
prompts/*.md'
areas "docs-exclude miss leaves docs alone" docs 'docs/guide.md' 'design/*'
areas "empty list is every area" $ALL ''
areas "blank lines only is every area" $ALL $'\n\n'
areas "generated protobuf TS is Go and UI" go,ui 'packages/app-ui/src/gen/v1/service_pb.ts'
areas "go.mod under packages/ is every area" $ALL 'packages/tool/go.mod'
areas "mixed Go + UI + docs" docs,go,ui \
'README.md
internal/x.go
packages/app-ui/src/App.tsx'
areas "licence variants are docs" docs \
'LICENSE.txt
LICENSE-MIT
third_party/lib/LICENSE
COPYING'
areas "LICENSE-looking code is not docs" ui 'web/src/LICENSE-modal.tsx'
areas "LICENSES/ directory is not docs" $ALL 'LICENSES/gen.sh'
areas "nested .claude/ Markdown is every area" $ALL 'services/api/.claude/README.md'
areas "rename Go -> docs (old + new path) is Go" docs,go \
'internal/x.go
docs/x.md'
areas "no trailing newline, CRLF" docs,go $'README.md\r\nmain.go'

# verdict NAME WANT(0|1) NEEDS_JSON
verdict() {
  local name=$1 want=$2 json=$3 rc=0
  bash "$VERDICT" <<<"$json" >/dev/null 2>&1 || rc=$?
  if [ "$want" = 0 ] && [ "$rc" = 0 ]; then pass "$name -> green"
  elif [ "$want" = 1 ] && [ "$rc" != 0 ]; then pass "$name -> red"
  else fail "$name: want $([ "$want" = 0 ] && echo green || echo red), exit $rc"
  fi
}

r() { printf '"%s":{"result":"%s","outputs":{}}' "$1" "$2"; }

echo
echo "suite verdict:"
verdict "all passed" 0 "{$(r changes success),$(r backend success),$(r ui success)}"
verdict "skipped by change detection" 0 "{$(r changes success),$(r backend skipped),$(r ui skipped)}"
verdict "one failed" 1 "{$(r changes success),$(r backend failure),$(r ui success)}"
verdict "one cancelled" 1 "{$(r changes success),$(r backend cancelled),$(r ui skipped)}"
verdict "changes failed, rest skipped" 1 "{$(r changes failure),$(r backend skipped),$(r ui skipped)}"
verdict "unknown result" 1 "{$(r changes success),$(r backend weird)}"
verdict "not JSON" 1 'not json'

echo
if [ "$failures" -gt 0 ]; then
  echo "FAIL: $failures case(s)"
  exit 1
fi
echo "PASS: change-area classifier and suite verdict"
