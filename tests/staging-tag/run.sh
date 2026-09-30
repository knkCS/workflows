#!/usr/bin/env bash
#
# Fixture self-test for scripts/update-staging-tag.sh, the step of
# staging-image.yml that writes a staging image's SHA into the deploy repo.
# Run by self-test.yml.
#
# Hermetic: the deploy repo is a throwaway local bare repository, so no token,
# no network and no real deploy repo. It pins what a wrong update would break
# silently or loudly on a busy morning:
#
#   - only the top-level `image.tag` is rewritten, never another `tag:` line;
#   - a values file already at the SHA is a clean no-op (no empty commit);
#   - a values file without `image.tag` fails, rather than committing nothing;
#   - a push that loses a race with another service's push is retried on top
#     of the new tip, and both commits survive, linearly;
#   - a race lost on every attempt fails after the attempts run out.
#
# Requires: bash, git.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
UPDATE="$REPO_ROOT/scripts/update-staging-tag.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export STAGING_TAG_RETRY_DELAY=0

failures=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

VALUES=environments/staging/services/svc-values.yaml
OLD=1111111111111111111111111111111111111111
NEW=2222222222222222222222222222222222222222

# A values file with every `tag:` line a naive substitution would also hit:
# a comment, a sidecar's image, a nested `image:` under another key, and a
# top-level `tag:` of its own.
values_with() {
  cat <<EOF
# Staging overrides for svc (tag: is written by CI)
image:
  repository: ghcr.io/knkcms/svc
  tag: "$1"  # the staging image
  pullPolicy: IfNotPresent

sidecar:
  image:
    repository: ghcr.io/knkcms/proxy
    tag: "v1.2.3"

tag: "keep-me"

resources:
  limits:
    memory: 512Mi
EOF
}

# new_deploy NAME CONTENT -> path of a fresh clone of a fresh bare origin whose
# main holds CONTENT at $VALUES.
new_deploy() {
  local name=$1 content=$2 seed="$WORK/$1-seed"
  git init -q --bare -b main "$WORK/$name.git"
  git init -q -b main "$seed"
  mkdir -p "$seed/$(dirname "$VALUES")"
  printf '%s\n' "$content" >"$seed/$VALUES"
  echo "other" >"$seed/other.txt"
  git -C "$seed" add -A
  git -C "$seed" commit -q -m seed
  git -C "$seed" push -q "$WORK/$name.git" main
  git clone -q "$WORK/$name.git" "$WORK/$name"
  echo "$WORK/$name"
}

# race_hook CLONE ONCE: install a pre-push hook in CLONE that, before the push
# reaches the origin, pushes a competing commit (another service's update) from
# a second clone — so CLONE's push is rejected. ONCE=true races only the first
# push; false races every push.
race_hook() {
  local clone=$1 once=$2 origin rival
  origin=$(git -C "$clone" remote get-url origin)
  rival="$clone-rival"
  git clone -q "$origin" "$rival"
  cat >"$clone/.git/hooks/pre-push" <<EOF
#!/usr/bin/env bash
set -e
if [ "$once" = true ] && [ -e "$rival/.raced" ]; then exit 0; fi
touch "$rival/.raced"
git -C "$rival" pull -q --ff-only
echo "\$(date +%s%N)" >>"$rival/other.txt"
git -C "$rival" commit -q -am "chore: update other image"
git -C "$rival" push -q origin main
EOF
  chmod +x "$clone/.git/hooks/pre-push"
}

run_update() { # CLONE [extra args] -> exit status; output in $WORK/out
  local clone=$1; shift
  bash "$UPDATE" --dir "$clone" --values "$VALUES" --tag "$NEW" \
    --message "chore: update svc image to $NEW" "$@" >"$WORK/out" 2>&1
}

origin_file() { git -C "$1" fetch -q origin && git -C "$1" show "origin/main:$VALUES"; }
origin_count() { git -C "$1" fetch -q origin && git -C "$1" rev-list --count origin/main; }

echo "staging tag update:"

# 1. Only image.tag changes, and the update is committed and pushed.
d=$(new_deploy only-image-tag "$(values_with "$OLD")")
if run_update "$d"; then
  if [ "$(origin_file "$d")" = "$(values_with "$NEW")" ]; then pass "rewrites image.tag only, keeps every other line"
  else fail "rewrites image.tag only: origin file differs:"; diff <(values_with "$NEW") <(origin_file "$d") || true
  fi
  msg=$(git -C "$d" log -1 --format=%s origin/main)
  [ "$msg" = "chore: update svc image to $NEW" ] && pass "commits with the given message" || fail "commit message: $msg"
else
  fail "rewrites image.tag only: exited non-zero"; cat "$WORK/out"
fi

# 2. Already at the tag: clean no-op, no commit.
d=$(new_deploy already "$(values_with "$NEW")")
before=$(origin_count "$d")
if run_update "$d"; then
  [ "$(origin_count "$d")" = "$before" ] && pass "already at the tag: no commit" || fail "already at the tag: a commit was pushed"
else
  fail "already at the tag: exited non-zero"; cat "$WORK/out"
fi

# 3. No image.tag: fail, push nothing.
d=$(new_deploy no-image-tag "$(printf 'image:\n  repository: ghcr.io/knkcms/svc\ntag: "x"\n')")
before=$(origin_count "$d")
if run_update "$d"; then fail "no image.tag: exited zero"
else
  [ "$(origin_count "$d")" = "$before" ] && pass "no image.tag: fails, pushes nothing" || fail "no image.tag: a commit was pushed"
fi

# 4. Missing values file: fail.
d=$(new_deploy missing "$(values_with "$OLD")")
if bash "$UPDATE" --dir "$d" --values does/not/exist.yaml --tag "$NEW" --message m >"$WORK/out" 2>&1; then
  fail "missing values file: exited zero"
else pass "missing values file: fails"
fi

# 5. Lost push race: retried on the new tip, both commits kept, linear history.
d=$(new_deploy race-once "$(values_with "$OLD")")
race_hook "$d" true
before=$(origin_count "$d")
if run_update "$d" --attempts 3; then
  after=$(origin_count "$d")
  if [ "$after" = $((before + 2)) ] && [ "$(origin_file "$d")" = "$(values_with "$NEW")" ] \
     && [ "$(git -C "$d" log -1 --format=%s origin/main~1)" = "chore: update other image" ] \
     && [ "$(git -C "$d" rev-list --merges --count origin/main)" = 0 ]; then
    pass "lost push race: retried on top of the rival commit"
  else
    fail "lost push race: origin has $after commits (want $((before + 2)))"; git -C "$d" log --oneline origin/main
  fi
else
  fail "lost push race: exited non-zero"; cat "$WORK/out"
fi

# 6. Race lost on every attempt: fails after the attempts run out.
d=$(new_deploy race-always "$(values_with "$OLD")")
race_hook "$d" false
if run_update "$d" --attempts 2; then fail "race lost every time: exited zero"
else
  [ "$(grep -c 'attempt [0-9]' "$WORK/out")" -ge 2 ] && pass "race lost every time: fails after 2 attempts" \
    || { fail "race lost every time: did not try twice"; cat "$WORK/out"; }
fi

echo
if [ "$failures" -gt 0 ]; then echo "FAIL: $failures case(s)"; exit 1; fi
echo "PASS: staging tag update"
