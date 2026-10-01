#!/usr/bin/env bash
#
# Self-test for actions/configure-private-modules (its configure.sh), the step
# of go-service-ci's `go` job — in both modes — that lets Go fetch private
# modules. Run by self-test.yml.
#
# Hermetic: the private modules are throwaway local git repos standing in for
# github.com/knkcs/lib and github.com/knkcms/knkeditor/go (a module in a repo
# subdirectory, as fieldkit's dependency is), reached through git's own
# url.insteadOf. GOPROXY=off makes the public proxy unreachable, so a module
# resolves only if GOPRIVATE routes it straight to git, and — with no go.sum —
# only if GONOSUMDB (which defaults to GOPRIVATE) keeps it away from the
# checksum database. It pins:
#
#   - the default GOPRIVATE covers both orgs, knkCS and knkcms, spelled in
#     lowercase as their Go module paths are (Go matches the patterns
#     case-sensitively);
#   - a module depending on a private knkcms module resolves it — and does NOT
#     under the old knkCS-only GOPRIVATE, so the test tells the two apart;
#   - a knkCS-only module resolves under both the old and the new value;
#   - CI_TOKEN is injected for every github.com URL (one insteadOf, whatever
#     the org), and a second run does not stack a second rewrite;
#   - `extra-patterns` appends to the default, never replaces it.
#
# Requires: bash, git, go.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
CONFIGURE="$REPO_ROOT/actions/configure-private-modules/configure.sh"

WORK="$(mktemp -d)"
# The module cache is read-only by design.
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_NOSYSTEM=1
# Go must not inherit the developer's or the runner's own Go settings.
unset GOPRIVATE GONOPROXY GONOSUMDB GOFLAGS GOINSECURE
export GOWORK=off GOTOOLCHAIN=local GOPROXY=off GOENV=off
export GOMODCACHE="$WORK/modcache" GOCACHE="$WORK/gocache"

failures=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

DEFAULT='github.com/knkcs/*,github.com/knkcms/*'
OLD='github.com/knkcs/*'
TOKEN=test-token

# seed_remote ORG/REPO SUBDIR MODULE TAG -> a bare repo at
# $WORK/remotes/ORG/REPO.git holding MODULE in SUBDIR, tagged TAG.
seed_remote() {
  local repo=$1 sub=$2 module=$3 tag=$4 seed="$WORK/seed/$1"
  git init -q -b main "$seed"
  mkdir -p "$seed/$sub"
  printf 'module %s\n\ngo 1.21\n' "$module" >"$seed/$sub/go.mod"
  printf 'package lib\n\nconst Name = "%s"\n' "$module" >"$seed/$sub/lib.go"
  git -C "$seed" add -A
  git -C "$seed" commit -q -m seed
  git -C "$seed" tag "$tag"
  git init -q --bare -b main "$WORK/remotes/$repo.git"
  git -C "$seed" push -q "$WORK/remotes/$repo.git" main "$tag"
}
seed_remote knkcs/lib . github.com/knkcs/lib v0.1.0
seed_remote knkcms/knkeditor go github.com/knkcms/knkeditor/go go/v0.1.0

# configure NAME [EXTRA] -> runs configure.sh as the action does, into
# $WORK/env-NAME (the GITHUB_ENV file) and $WORK/git-NAME (the global config).
configure() {
  GITHUB_ENV="$WORK/env-$1" GIT_CONFIG_GLOBAL="$WORK/git-$1" \
    CI_TOKEN=$TOKEN EXTRA_PATTERNS=${2:-} bash "$CONFIGURE"
}

rewrites() {
  GIT_CONFIG_GLOBAL="$WORK/git-$1" git config --global --get-regexp '^url\..*\.insteadof$' || true
}

# resolve NAME GOPRIVATE REQUIRE... -> 0 if a consumer module requiring each
# "MODULE VERSION" downloads them all. The git config is the one configure.sh
# wrote for `default`, plus the test's redirect of each org's https URL onto
# the local remotes — a longer key than the action's https://github.com/, so
# it wins (the token rewrite itself is asserted on the config above).
resolve() {
  local name=$1 goprivate=$2; shift 2
  local mod="$WORK/consumer-$name" cfg="$WORK/gitconfig-$name" org
  cp "$WORK/git-default" "$cfg"
  for org in knkcs knkcms; do
    GIT_CONFIG_GLOBAL=$cfg git config --global "url.file://$WORK/remotes/$org/.insteadOf" "https://github.com/$org/"
  done
  mkdir -p "$mod"
  { printf 'module example.com/consumer\n\ngo 1.21\n\nrequire (\n'
    printf '\t%s\n' "$@"
    printf ')\n'; } >"$mod/go.mod"
  chmod -R u+w "$GOMODCACHE" 2>/dev/null || true
  rm -rf "$GOMODCACHE"
  (cd "$mod" && GIT_CONFIG_GLOBAL=$cfg GOPRIVATE=$goprivate go mod download all) >"$WORK/out-$name" 2>&1
}

# --- 1. The default covers both orgs; one token rewrite for all of github.com.
configure default
got=$(cat "$WORK/env-default")
[ "$got" = "GOPRIVATE=$DEFAULT" ] && pass "default GOPRIVATE covers knkcs and knkcms" \
  || fail "default GOPRIVATE: got '$got', want 'GOPRIVATE=$DEFAULT'"
goprivate=${got#GOPRIVATE=}
[ "$goprivate" = "$(printf '%s' "$goprivate" | tr '[:upper:]' '[:lower:]')" ] \
  && pass "default patterns are lowercase, as the orgs' module paths are" \
  || fail "default patterns are not lowercase: $goprivate"

for var in GONOPROXY GONOSUMDB; do
  v=$(GOPRIVATE=$goprivate go env "$var")
  [ "$v" = "$goprivate" ] && pass "$var follows GOPRIVATE: both orgs bypass the proxy and checksum db" \
    || fail "$var: got '$v', want '$goprivate'"
done

want_rewrite="url.https://$TOKEN@github.com/.insteadof https://github.com/"
[ "$(rewrites default)" = "$want_rewrite" ] && pass "one insteadOf injects CI_TOKEN for every github.com org" \
  || fail "insteadOf: got '$(rewrites default)', want '$want_rewrite'"

# --- 2. A private knkcms dependency resolves (fieldkit's case). ---
if resolve knkcms "$goprivate" 'github.com/knkcms/knkeditor/go v0.1.0'; then
  pass "knkcms dependency resolves under the default GOPRIVATE"
else
  fail "knkcms dependency did not resolve"; cat "$WORK/out-knkcms"
fi
# ... and does not under the old knkCS-only value: the test discriminates.
if resolve knkcms-old "$OLD" 'github.com/knkcms/knkeditor/go v0.1.0'; then
  fail "knkcms dependency resolved under the old knkCS-only GOPRIVATE: the test does not discriminate"
elif grep -q 'GOPROXY=off' "$WORK/out-knkcms-old"; then
  pass "knkcms dependency fails under the old knkCS-only GOPRIVATE (sent to the proxy)"
else
  fail "knkcms dependency failed under the old GOPRIVATE, but not at the proxy"; cat "$WORK/out-knkcms-old"
fi

# --- 3. A knkCS-only caller is unaffected. ---
if resolve knkcs-old "$OLD" 'github.com/knkcs/lib v0.1.0'; then
  pass "knkCS-only dependency resolves under the old GOPRIVATE (baseline)"
else
  fail "knkCS-only dependency did not resolve under the old GOPRIVATE"; cat "$WORK/out-knkcs-old"
fi
if resolve knkcs "$goprivate" 'github.com/knkcs/lib v0.1.0'; then
  pass "knkCS-only dependency resolves under the default GOPRIVATE"
else
  fail "knkCS-only dependency did not resolve under the default GOPRIVATE"; cat "$WORK/out-knkcs"
fi
if resolve both "$goprivate" 'github.com/knkcs/lib v0.1.0' 'github.com/knkcms/knkeditor/go v0.1.0'; then
  pass "dependencies in both orgs resolve together"
else
  fail "dependencies in both orgs did not resolve together"; cat "$WORK/out-both"
fi

# --- 4. A second run (the action used twice in a job) changes nothing. ---
configure default
[ "$(rewrites default)" = "$want_rewrite" ] && pass "a second run leaves one insteadOf" \
  || fail "after a second run: '$(rewrites default)'"

# --- 5. extra-patterns append to the default, as written. ---
# Run where a pattern would match a file, to prove it is not glob-expanded.
mkdir -p "$WORK/glob/github.com/acme/repo"
(cd "$WORK/glob" && configure extra ' github.com/acme/*, gitlab.com/x/y
example.com/z ')
got=$(cat "$WORK/env-extra")
want="GOPRIVATE=$DEFAULT,github.com/acme/*,gitlab.com/x/y,example.com/z"
[ "$got" = "$want" ] && pass "extra-patterns are appended (comma, space or newline separated), never glob-expanded" \
  || fail "extra-patterns: got '$got', want '$want'"

echo
if [ "$failures" -gt 0 ]; then echo "FAIL: $failures case(s)"; exit 1; fi
echo "PASS: private modules"
