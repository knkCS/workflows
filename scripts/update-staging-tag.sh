#!/usr/bin/env bash
#
# Write a staging image's tag into a service's staging values file in the
# deploy repo, commit it and push it.
#
#   update-staging-tag.sh --dir CLONE --values PATH --tag TAG --message MSG [--attempts N]
#
# CLONE is a clone of the deploy repo on the branch to update (staging-image.yml
# checks it out with CI_TOKEN and sets the committer). PATH is the values file,
# relative to CLONE. The caller sets the git identity.
#
# What it rewrites: only the top-level `image.tag` — the `tag:` line that is a
# direct child of the column-0 `image:` key — keeping its indentation and any
# trailing comment. Every other `tag:` line (a sidecar's image, a nested
# `image:` under another key, a top-level `tag:`) is left alone. No `image.tag`
# in the file fails the run: a staging image that nothing points at must be
# loud.
#
# Already at TAG (a re-run, or a run of the same commit): exit 0, no commit.
#
# Concurrency: several services update the deploy repo around the same time,
# so a push can lose the race. On a rejected push it fetches the new tip,
# resets onto it and applies the edit again — a rebase that cannot conflict,
# because the edit is re-derived from the new tip instead of replayed onto it —
# and retries, up to N attempts (default 5) with a growing pause
# (STAGING_TAG_RETRY_DELAY seconds x attempt, default 3).
#
# Requires: bash, git, awk.
set -euo pipefail

dir="" values="" tag="" message="" attempts=5
while [ $# -gt 0 ]; do
  case $1 in
    --dir) dir=$2; shift 2 ;;
    --values) values=$2; shift 2 ;;
    --tag) tag=$2; shift 2 ;;
    --message) message=$2; shift 2 ;;
    --attempts) attempts=$2; shift 2 ;;
    *) echo "::error::update-staging-tag: unknown argument $1" >&2; exit 2 ;;
  esac
done
for v in dir values tag message; do
  [ -n "${!v}" ] || { echo "::error::update-staging-tag: --$v is required" >&2; exit 2; }
done
# The tag lands inside a quoted YAML scalar: allow only what an image tag can be.
[[ $tag =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] \
  || { echo "::error::update-staging-tag: '$tag' is not a valid image tag" >&2; exit 2; }
delay=${STAGING_TAG_RETRY_DELAY:-3}

# set_image_tag FILE: rewrite FILE's top-level image.tag to $tag in place.
# Exit 3 when there is none.
set_image_tag() {
  local file=$1 tmp
  tmp=$(mktemp)
  if awk -v tag="$tag" '
    function indent_of(s) { match(s, /^[ \t]*/); return substr(s, 1, RLENGTH) }
    /^image:[ \t]*(#.*)?$/ { in_image = 1; child = ""; print; next }
    in_image && /^[^ \t#]/ { in_image = 0 }
    in_image && !/^[ \t]*(#.*)?$/ {
      ind = indent_of($0)
      if (child == "") child = ind
      rest = substr($0, length(ind) + 1)
      if (!done && ind == child && rest ~ /^tag:/) {
        comment = ""
        if (match(rest, /[ \t]+#.*$/)) comment = substr(rest, RSTART)
        print ind "tag: \"" tag "\"" comment
        done = 1
        next
      }
    }
    { print }
    END { exit done ? 0 : 3 }
  ' "$file" >"$tmp"; then
    cat "$tmp" >"$file"
    rm -f "$tmp"
  else
    local rc=$?
    rm -f "$tmp"
    return "$rc"
  fi
}

cd "$dir"
branch=$(git symbolic-ref --short HEAD)

for attempt in $(seq 1 "$attempts"); do
  echo "attempt $attempt/$attempts: $values -> $tag"
  git fetch -q origin "$branch"
  git reset -q --hard "origin/$branch"
  if [ ! -f "$values" ]; then
    echo "::error::update-staging-tag: $values does not exist in the deploy repo"
    exit 1
  fi
  rc=0
  set_image_tag "$values" || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -eq 3 ] && echo "::error::update-staging-tag: $values has no top-level image.tag"
    exit 1
  fi
  if git diff --quiet -- "$values"; then
    echo "$values is already at $tag; nothing to commit"
    exit 0
  fi
  git add -- "$values"
  git commit -q -m "$message"
  if git push -q origin "HEAD:$branch"; then
    echo "pushed $(git rev-parse --short HEAD) to $branch"
    exit 0
  fi
  echo "push rejected (the deploy repo moved); retrying on its new tip"
  [ "$attempt" -lt "$attempts" ] && sleep $((delay * attempt))
done

echo "::error::update-staging-tag: push still rejected after $attempts attempts"
exit 1
