#!/usr/bin/env bash
#
# Change-area classifier: which change areas a pull request touches.
#
#   change-areas.sh [--docs-exclude PATTERNS] [--go-dir DIR]... [--ui-dir DIR]... < changed-paths
#
# Reads repo-relative file paths, one per line, on stdin and prints one line
# per change area, in a fixed order, ready to append to $GITHUB_OUTPUT:
#
#   docs=true|false
#   go=true|false
#   ui=true|false
#   image=true|false
#
# PATTERNS is a whitespace- or newline-separated list of shell globs matched
# against the whole path (`*` crosses `/`, so `design/*` covers everything
# below design/). A path matching one is never docs — it is classified by the
# remaining rules as if it were not Markdown.
#
# --go-dir and --ui-dir (repeatable) give the caller's own layout a home: every
# path under DIR/ is Go, or UI, as if it matched that area's patterns below.
# go-service-ci passes its `working-directory` and `helm-chart` as Go dirs (the
# `go` job vets, tests and helm-lints them) and its `ui-package` as a UI dir, so
# a module in go/, a chart in charts/<name>/ or a UI package outside packages/
# stops counting as every area. DIR is literal (no globs); a leading ./ and a
# trailing / are dropped; an empty DIR or `.` is ignored, since the repo root
# would claim every path. A dir only ever ADDS a home — docs, image and *.go
# still win inside it, and a path claimed by both Go and UI is every area.
#
# go-service-ci's `changes` job calls this; tests/change-areas/run.sh is its
# fixture self-test. The rules (knkCS/workflows#21):
#
#   docs   **/*.md, docs/**, .scratch/**, licence files (a basename of
#          LICENSE, LICENSE.txt or LICENSE-<NAME>), issue and PR templates
#          under .github/, the release-please manifest.
#          Never docs, whatever the extension: **/testdata/**, **/fixtures/**,
#          **/__fixtures__/**, anything matching --docs-exclude.
#   image  Dockerfile*, .dockerignore, docker/**.
#   Go     *.go (always, even under a web directory), go.mod/go.sum/go.work
#          anywhere, *.proto, api/**, buf*.yaml, .golangci.y*ml, migrations/**.
#   UI     web/**, packages/**, package.json, package-lock.json, .npmrc.
#          Generated protobuf output under a UI src/gen/ directory counts as Go
#          and UI: a Go job regenerates it, so a hand-edit must reach one.
#
# The conservative rule is the point of the whole design: a path that matches
# NO area — a Makefile, a workflow, a chart not given as --go-dir, a Markdown
# fixture, anything under .claude/ — turns on EVERY area, and so does a path
# matching both Go and UI
# (e.g. packages/foo/go.mod). An empty list also means every area: nothing to
# classify is not evidence that nothing needs checking. So the only way this
# script can be wrong is by running too much, never too little.
#
# Plain bash (3.2-compatible) with no dependencies, so it runs on any runner.
set -euo pipefail
set -f # the patterns below and in --docs-exclude are globs for `case`, never for the filesystem

docs_exclude=""
go_dirs="" ui_dirs="" # newline-separated, normalised

# normalise_dir DIR: drop leading ./ and trailing /; print nothing for the root.
normalise_dir() {
  local d=$1
  while case $d in ./*) true ;; *) false ;; esac; do d=${d#./}; done
  while case $d in */) true ;; *) false ;; esac; do d=${d%/}; done
  case $d in ''|.) return 0 ;; esac
  printf '%s\n' "$d"
}

while [ $# -gt 0 ]; do
  case $1 in
    --docs-exclude) docs_exclude=${2-}; shift 2 || { echo "change-areas: --docs-exclude needs a value" >&2; exit 2; } ;;
    --docs-exclude=*) docs_exclude=${1#--docs-exclude=}; shift ;;
    --go-dir|--ui-dir)
      [ $# -ge 2 ] || { echo "change-areas: $1 needs a value" >&2; exit 2; }
      d=$(normalise_dir "$2")
      if [ -n "$d" ]; then
        if [ "$1" = --go-dir ]; then go_dirs="$go_dirs$d"$'\n'; else ui_dirs="$ui_dirs$d"$'\n'; fi
      fi
      shift 2 ;;
    *) echo "change-areas: unknown argument: $1" >&2; exit 2 ;;
  esac
done

docs=false go=false ui=false image=false
all() { docs=true go=true ui=true image=true; }

never_docs() {
  case $1 in
    testdata/*|*/testdata/*|fixtures/*|*/fixtures/*|__fixtures__/*|*/__fixtures__/*) return 0 ;;
  esac
  local p
  for p in $docs_exclude; do
    # shellcheck disable=SC2254 # $p is deliberately a pattern
    case $1 in $p) return 0 ;; esac
  done
  return 1
}

is_docs() {
  case $1 in
    *.md|docs/*|.scratch/*) return 0 ;;
    .github/ISSUE_TEMPLATE/*|.github/PULL_REQUEST_TEMPLATE*|.github/pull_request_template*) return 0 ;;
    .release-please-manifest.json) return 0 ;;
  esac
  # A licence file, judged by its basename alone: `LICENSE*` over the whole path
  # would also match web/src/LICENSE-modal.tsx or LICENSES/gen.ts, which are code.
  case ${1##*/} in
    LICENSE-*.*) return 1 ;;
    LICENSE|LICENSE.txt|LICENSE-*|LICENCE|LICENCE.txt|COPYING) return 0 ;;
  esac
  return 1
}

is_image() {
  case $1 in
    Dockerfile*|*/Dockerfile*|.dockerignore|*/.dockerignore|docker/*) return 0 ;;
  esac
  return 1
}

# under_dir PATH DIRS: PATH lies below one of the newline-separated DIRS.
under_dir() {
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    case $1 in "$d"/*) return 0 ;; esac
  done <<<"$2"
  return 1
}

is_go() {
  if under_dir "$1" "$go_dirs"; then return 0; fi
  case $1 in
    *.go|go.mod|go.sum|go.work|go.work.sum|*/go.mod|*/go.sum|*/go.work|*/go.work.sum) return 0 ;;
    *.proto|api/*|buf.yaml|buf.gen.yaml|buf.work.yaml|.golangci.yml|.golangci.yaml|migrations/*) return 0 ;;
  esac
  return 1
}

is_ui() {
  if under_dir "$1" "$ui_dirs"; then return 0; fi
  case $1 in
    web/*|packages/*|package.json|package-lock.json|.npmrc) return 0 ;;
  esac
  return 1
}

is_generated_ui() {
  case $1 in
    packages/*/src/gen/*|web/src/gen/*) return 0 ;;
  esac
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    case $1 in "$d"/src/gen/*) return 0 ;; esac
  done <<<"$ui_dirs"
  return 1
}

seen=0
while IFS= read -r f || [ -n "$f" ]; do
  f=${f%$'\r'}
  [ -n "$f" ] || continue
  seen=$((seen + 1))

  # .claude/ (agent hooks, settings, skills) is deliberately in no area, so it
  # turns everything on — even its Markdown and any Go file in it.
  case $f in .claude/*|*/.claude/*) echo "change-areas: $f is under .claude/, which is in no area; counting it as every area" >&2; all; continue ;; esac

  # *.go next: a Go file is Go wherever it lives, docs/ and web/ included.
  case $f in *.go) go=true; continue ;; esac

  if ! never_docs "$f" && is_docs "$f"; then docs=true; continue; fi
  if is_image "$f"; then image=true; continue; fi
  if is_generated_ui "$f"; then go=true; ui=true; continue; fi

  g=false u=false
  if is_go "$f"; then g=true; fi
  if is_ui "$f"; then u=true; fi
  if [ "$g" = true ] && [ "$u" = true ]; then
    echo "change-areas: $f matches both Go and UI; counting it as every area" >&2
    all; continue
  fi
  if [ "$g" = true ]; then go=true; continue; fi
  if [ "$u" = true ]; then ui=true; continue; fi

  echo "change-areas: $f is in no known change area; counting it as every area" >&2
  all
done

if [ "$seen" -eq 0 ]; then
  echo "change-areas: no changed files; counting that as every area" >&2
  all
fi

printf 'docs=%s\ngo=%s\nui=%s\nimage=%s\n' "$docs" "$go" "$ui" "$image"
