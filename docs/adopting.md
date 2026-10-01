# Adopting knkcs/workflows

How a repo in `knkCS` or `knkcms` becomes a **caller** of this repo: copy the
**caller templates** for its publish model, fill in the placeholders, and work
through the checklist below. Nothing here needs reverse-engineering another
repo — if you find you do, this guide is missing something; fix it here.

The vocabulary (PR suite, merge check, suite verdict, release, staging image,
change area, caller template) is defined in [`CONTEXT.md`](../CONTEXT.md); the
decisions behind the rules are ADRs [0001](adr/0001-arm64-is-a-developer-platform-built-natively.md)
(arm64 only by native build), [0002](adr/0002-knkcs-stays-on-free-without-enforced-checks.md)
(knkCS checks are advisory) and [0003](adr/0003-callers-pin-v1-only.md)
(`@v1` only). Every input of every shared workflow is documented in the
[README](../README.md).

> **Check `v1` first.** The templates need the PR suite and merge check rework
> of `go-service-ci` — `mode`, change areas, `ci-ok`, `working-directory`,
> `image-check` and the timeout inputs — and the staging image workflow. `v1`
> moves to them once statushub's pilot (#29) is green; that pilot proved the
> PR suite and the release `main` template, and the staging image template is
> first piloted on layout (#30). If
> `git ls-remote https://github.com/knkcs/workflows refs/tags/v1` still shows
> `7d6dc74…`, `v1` has not moved yet and a copied template fails at startup
> (an undeclared input is an error, not ignored — ADR 0003): wait, and do not
> work around it with a SHA or `@main` pin.

## The caller templates

| Template | Copy to | For | What it wires |
|---|---|---|---|
| [`templates/pr.yml`](../templates/pr.yml) | `.github/workflows/ci.yml` | both publish models | The PR suite: `go-service-ci` on `pull_request`, superseded runs cancelled |
| [`templates/commitlint.yml`](../templates/commitlint.yml) | `.github/workflows/commitlint.yml` | both publish models | Conventional-commit linting on `pull_request` |
| [`templates/release/main.yml`](../templates/release/main.yml) | `.github/workflows/main.yml` | the release model | On `push: main`: merge check → release-please → `publish-image-chart` / `publish-ui` |
| [`templates/staging-image/main.yml`](../templates/staging-image/main.yml) | `.github/workflows/main.yml` | the staging image model | On `push: main`: merge check → `staging-image` |

The PR suite template sits at the top of `templates/`, not under a publish
model, because it is the same file for both: what differs between the models
is only what happens on `main`.

Every template carries the same concurrency block:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

One group per workflow and PR (or ref). A new push to a PR cancels its
superseded run; a run on `main` is never cancelled, because `main` publishes —
it queues behind the one in progress. (GitHub keeps one *pending* run per
group, so a burst of merges runs the first and the last; the last checks the
newest tree and release-please reads the whole history. A skipped run's
release is still cut by the last one, which is why every publish builds the
release tag, not the run's commit — [Release](#release).)
Keep the block verbatim: it is identical everywhere precisely so that copying
it into the wrong file cannot cancel a publish.

This repo's self-test lints every template with actionlint and runs
`tests/caller-templates/run.sh`, which checks what actionlint cannot see
across the `@v1` boundary: every input and secret a template passes is one the
called workflow declares, every call is `@v1`, and the `main` templates gate
everything on the merge check.

## Adopting, step by step

1. **Pick the publish model.** knkCS repos use the [release](#release) model;
   knkcms repos whose staging follows `main` use the
   [staging image](#staging-image) model.
2. **Set the `CI_TOKEN` secret** with the access your repo needs
   ([below](#the-ci_token-secret)).
3. **Copy `templates/pr.yml` and `templates/commitlint.yml`.** Fill in the
   `<placeholders>`; delete the inputs you do not need (the README's
   `go-service-ci` input table says what each does). Remove `push: main`
   from the existing PR suite workflow — `main` runs the merge check instead.
4. **Copy your model's `main` template.** It replaces the repo's existing
   release workflow. Pass the merge check exactly the `go-version-file`,
   `working-directory` and `runs-on` the PR suite passes, and the same layout
   inputs (`helm-chart`, `ui-package`, `embed-frontend`, `frontend-build`,
   `check-ent-drift`, `check-gofmt`), so it checks the same tree and warms the
   caches PRs restore.
5. **Configure release-please** (release model,
   [below](#release-please-configuration)), or check the deploy repo's
   staging values file (staging image model, [below](#staging-image)).
6. **Make the Dockerfile conform** ([below](#dockerfile-requirements)), then
   turn on `image-check` in the PR suite.
7. **Wait for — and where the plan allows, require — the suite verdict**
   ([below](#requiring-the-suite-verdict)).
8. **Audit the repo against the [anti-pattern checklist](#anti-pattern-checklist)**
   and delete what it finds.
9. **Update your row in the [adoption status](#adoption-status) table.**

A repo-specific check the shared workflow cannot express (a scope check, a
second Go module, buf, a frontend suite `ui-test` does not cover) stays a job
of its own in the caller's `ci.yml`, beside the `ci` job — with its own
`timeout-minutes`, and inheriting the file's concurrency. Say in a comment why
it cannot be an input, and prefer asking for the input here if it would
generalise.

## The `CI_TOKEN` secret

`CI_TOKEN` is the `knk-ci` fine-grained PAT, stored as a **repository secret**
in each caller (not an org secret today). This repo's workflows contain no
secrets; the caller passes it by name at call time:

```yaml
    secrets:
      CI_TOKEN: ${{ secrets.CI_TOKEN }}
```

Pass secrets by name, not `secrets: inherit`: a called workflow then sees only
what it needs, and it is visible in the caller which job gets which token.

What it needs access to — **read-only**, unless noted:

| Used by | For | Access |
|---|---|---|
| `go-service-ci` (`go` job) | Private Go modules via `configure-private-modules` (sets `GOPRIVATE=github.com/knkcs/*,github.com/knkcms/*`, plus any `go-private-extra`) | Contents: read on **every** private repo the caller's module graph depends on, in either org — e.g. fieldkit (knkCS) → `knkcms/knkeditor`. A dependency the token cannot read fails the `go` job at module download |
| `go-service-ci` with `npm-github-packages` | `npm ci` from `npm.pkg.github.com` | `read:packages` for every scope the lockfile pulls (GitHub Packages needs a token even for public packages) |
| `go-service-ci` `image` job, `publish-image-chart` | The Dockerfile's BuildKit secret `ci_token` | Whatever the Dockerfile fetches with it — normally the same module access as above |
| `argocd-rendering-check` | Charts pulled from private service repos | Contents: read on each of those repos |
| `staging-image` | Committing the SHA into the deploy repo's staging values (`update-staging`) | Contents: **write** on the deploy repo (`knkcms/deploy` by default) |

Not used for: pushing images and charts to GHCR (the workflow's own
`GITHUB_TOKEN`, with `packages: write` granted by the caller) and publishing to
public npm (`NPM_TOKEN`, or `GITHUB_TOKEN` for GitHub Packages).

**Do not pass `CI_TOKEN` to `release-please`.** release-please prefers it over
`GITHUB_TOKEN` whenever it is present, and with a read-only token its first
write fails with a masked `Error adding to tree` (statushub hit exactly
this; odon's release workflow records the same limit). Without it, release-please uses `GITHUB_TOKEN`, which is enough on
knkCS. The consequence: a release PR opened with `GITHUB_TOKEN` starts no
`pull_request` workflow, so it gets no PR suite of its own. The merge check
still runs when it merges, and gates the publish.

The token must never reach an image: it goes into a build only as a BuildKit
secret, never a build-arg ([Dockerfile requirements](#dockerfile-requirements)).
Once no caller passes it as a build-arg any more, it is rotated (#36).

## Publish models

### Release

The knkCS model. A **release** is cut when a release-please PR merges; the
image, chart and UI package are published from that release, never from an
arbitrary `main` commit, so `:latest` means the newest release.

`templates/release/main.yml` runs on every push to `main`:

```text
merge-check ──► release-please ──► publish-image-chart  (if the root component released)
                               └─► publish-ui           (if the UI package released)
```

- **The merge check gates everything.** `release-please` `needs:` the merge
  check job, so a `main` where two green PRs no longer compile together opens
  no release PR, cuts no tag and publishes nothing. On knkCS this is the only
  safety net (ADR 0002).
- **Publishing lives in the same workflow**, gated with `if:` on
  release-please's outputs. A release created with `GITHUB_TOKEN` triggers no
  other workflow, so an `on: push: tags` publish workflow would never run for
  it.
- **Output names.** The root (`.`) component's outputs are unprefixed
  (`release_created`, `version`); every other component's are prefixed with
  its path and `--` (`packages/<name>-ui--release_created`,
  `packages/<name>-ui--tag_name`). Read them through `outputs_json`, as the
  template does.
- **Publishing builds the release tag, never `github.sha`.** Each publish job
  passes release-please's `tag_name` output as `ref` — the root's (`v<version>`)
  to `publish-image-chart`, the UI package's
  (`packages/<name>-ui--tag_name`, `<name>-ui-v<version>`) to `publish-ui` —
  and both check that ref out. The run's own commit is not safe to build:
  `main` queues and GitHub keeps only one pending run, so when a commit lands
  while a release PR's merge run is still pending, that run is replaced.
  release-please in the newer run still cuts the release, tagged at the
  release PR's merge commit, but `github.sha` is then the newer, unreleased
  commit — and vX's image, chart, UI package and `:latest` would be built
  from it. The tag is always vX's tree. `tests/caller-templates/run.sh` fails
  a release template whose publish job omits `ref`.
- **Permissions per job.** The workflow grants `contents: read`; the
  release-please job adds `contents: write` and `pull-requests: write`, the
  publish jobs `packages: write`. A called workflow can never have more than
  its calling job grants.
- **Keep a manual escape hatch** if you want one: a `workflow_dispatch`
  workflow calling `publish-image-chart` with `ref: v<version>` republishes a
  release without a new merge (statushub's `publish-image-manual.yml`).

A repo that releases only a Go module (versionkit) deletes both publish jobs; a
repo without a UI package deletes `publish-ui`; the merge check and the
`needs:` stay.

#### release-please configuration

Two files at the repo root, read by `release-please.yml` (override the paths
with its `config-file` / `manifest-file` inputs):

- `release-please-config.json` — one entry under `packages` per released
  component. The service at `.` with `"release-type": "go"`, and
  `"include-component-in-tag": false` so its tags are plain `vX.Y.Z` — the
  `version` `publish-image-chart` receives and the ref a manual republish
  builds from. A UI package at its path with `"release-type": "node"`, a
  `component` and `"include-component-in-tag": true`, so its tags are
  `<component>-vX.Y.Z` — `publish-ui`'s `tag-prefix` is `<component>-v`. Extra
  Go modules released in lockstep (`gen`, `client`) go in a `linked-versions`
  plugin group. `"bump-minor-pre-major": true` keeps a `feat!` below 1.0 from
  cutting 1.0.0.
- `.release-please-manifest.json` — the current version of each component,
  written by release-please. It counts as docs for change detection, so a
  release PR that only bumps it runs no suite.

statushub's config is the reference:

```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "tag-separator": "-",
  "bump-minor-pre-major": true,
  "packages": {
    ".": { "release-type": "go", "component": "<name>", "include-component-in-tag": false },
    "packages/<name>-ui": {
      "release-type": "node", "component": "<name>-ui",
      "package-name": "@knkcs/<name>-ui", "include-component-in-tag": true
    }
  }
}
```

Versions come from the conventional-commit types on `main` (`feat` → minor,
`fix` → patch, `!` → breaking), which is why `commitlint.yml` runs on every PR:
a mislabelled commit ships a wrong version.

### Staging image

The knkcms model. Staging follows `main`: every push to `main` publishes a
**staging image** tagged with the commit SHA (and `latest`) and points the
deploy repo's staging values at it — no release, no version.

`templates/staging-image/main.yml` runs on every push to `main`:

```text
merge-check ──► staging-image ──► publish (image + chart) ──► update-staging (deploy repo)
```

- **The merge check gates it**, exactly as in the release model: staging never
  receives a `main` that does not compile.
- **The build is the release model's.** `staging-image` calls
  `publish-image-chart` with the SHA as `version`: each architecture on its
  own native runner (ADR 0001), GHA-cached, merged into one manifest tagged
  `<sha>` and `latest`. The chart is pushed at the version its `Chart.yaml`
  declares, since a SHA is no chart version.
- **The deploy repo** (`deploy-repo`, default `knkcms/deploy`) gets the SHA in
  the top-level `image.tag` of `staging-values-path` — nothing else in the
  file — committed as `github-actions[bot]`. The values file must already have
  an `image.tag`; a run whose SHA is already there commits nothing, and a
  push race with another service's update is retried on the new tip.
- **Never cancel on `main`**: a cancelled run can leave the image pushed and
  staging not pointed at it. The shared concurrency block guarantees it.
- **A UI package** in a staging-image repo is still released through
  release-please and `publish-ui` (knkcms/template does); add those jobs
  behind the merge check as in the release template.

Inputs and the exact deploy-repo edit are in the README's
[`staging-image.yml`](../README.md#staging-imageyml-the-staging-image-publish-model)
section.

## Dockerfile requirements

Every image built by `publish-image-chart`, the `image-check` job of
`go-service-ci` or the staging image workflow must:

- **Take `CI_TOKEN` only as the BuildKit secret `ci_token`**, mounted for the
  one `RUN` that needs it — never `ARG`/`ENV`, never a `--build-arg`. A
  build-arg lands in the image's history and layers, readable by anyone who
  can pull it. Point git at the token through a throwaway config, so nothing
  of it persists in the layer:

  ```dockerfile
  # syntax=docker/dockerfile:1
  RUN --mount=type=secret,id=ci_token \
      --mount=type=cache,target=/go/pkg/mod \
      --mount=type=cache,target=/root/.cache/go-build \
      export GIT_CONFIG_GLOBAL=/tmp/git-ci-config && \
      git config --global url."https://$(cat /run/secrets/ci_token)@github.com/".insteadOf "https://github.com/" && \
      go mod download && \
      CGO_ENABLED=0 go build -ldflags="-w -s" -o /out/<name> ./cmd/<name> && \
      rm -f "$GIT_CONFIG_GLOBAL"
  ```

  (`ENV GOPRIVATE=github.com/knkcs/*,github.com/knkcms/*` in the stage, too.) `image-check` passes
  the secret on every PR build, so a Dockerfile without the mount still
  builds as long as it fetches nothing private.
- **Build natively, never under emulation** (ADR 0001). Every published image
  includes `linux/arm64` for developers, and arm64 may only come from a native
  build. `publish-image-chart` builds each architecture on a runner of that
  architecture, so any Dockerfile is native there. `staging-image` builds through it too.
  A Dockerfile that is built for both architectures on **one** runner
  (knkcms/template's hand-rolled release, until #31) must cross-compile: build stages `FROM --platform=$BUILDPLATFORM`, with the
  compiler targeting `$TARGETOS`/`$TARGETARCH`, so only the final stage — which
  runs nothing — is of the target architecture:

  ```dockerfile
  FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS build
  ARG TARGETOS TARGETARCH
  RUN ... GOOS=$TARGETOS GOARCH=$TARGETARCH CGO_ENABLED=0 go build ...
  FROM --platform=$BUILDPLATFORM node:24-alpine AS web   # npm ci runs natively too
  FROM gcr.io/distroless/static-debian12:nonroot
  COPY --from=build /out/<name> /usr/local/bin/<name>
  ```

  A `RUN` in a target-architecture stage (`npm ci`, `apk add`) is what hung
  for 6 hours under QEMU in September 2026. Never add `setup-qemu-action`.
- **Accept `VERSION`, `COMMIT` and `DATE` build-args** if it stamps them into
  the binary; `publish-image-chart` passes all three.
- **Live at `<image-context>/Dockerfile`** (the repo root by default) and keep
  its inputs under the image change area — `Dockerfile*`, `.dockerignore`,
  `docker/**` — or, being Go or UI files, under theirs.

## Requiring the suite verdict

`ci-ok` — shown as `ci / ci-ok` with the template's job name — is the **suite
verdict**: always reported, red if any check that ran failed or was cancelled,
green when change detection skipped a job. It is the one check to wait for, and
the only one to require:

- **knkcms** (Team plan): require `ci / ci-ok` in branch protection or a
  ruleset on `main`, and nothing else. Never require the individual jobs:
  GitHub reports a skipped job to branch protection as passing, whatever the
  reason it was skipped.
- **knkCS** (Free plan, ADR 0002): private repos cannot have branch protection,
  so nothing enforces it. Humans and agents wait for `ci / ci-ok` to be green
  before merging, and the merge check on `main` gates every release.

## Pinning: `@v1` only

Every `uses:` of this repo — reusable workflow or composite action — is
`@v1` (ADR 0003). Never a commit SHA, never `@main`, never a branch.

- `v1` moves on backward-compatible changes, so a cost or security fix here
  reaches every caller without a migration. Breaking changes go to `v2`.
- A SHA pin is not hermetic (`go-service-ci` calls its composite actions and
  scripts at `v1`/its own ref anyway), and it silently misses every later fix.
- The reason usually given for a SHA pin — "a reusable workflow ignores an
  input it does not declare" — is false: an undeclared input fails the run at
  startup, loudly. Nothing can silently turn a gate off.
- A change here is proven on one caller (statushub) against a branch ref of
  this repo before `v1` moves. That branch ref lives on a pilot PR only, never
  on `main` of a caller.

## Anti-pattern checklist

Run from the root of the caller, in bash. They are greps, so they
over-report: read every hit, and ask whether it is the anti-pattern — a
comment, or `cancel-in-progress: true` in a workflow that only runs on
`pull_request`, is fine. A caller that matches its templates prints nothing
but row 8's `uses:` lines, whose `needs:` you check by eye.

| # | Anti-pattern | Find it | Fix |
|---|---|---|---|
| 1 | **QEMU / emulated builds** — `setup-qemu-action`, or `platforms:` with `arm64` on one runner over a Dockerfile that does not cross-compile | `grep -rn 'setup-qemu-action' .github/workflows/` and `grep -rn 'platforms:.*arm64' .github/workflows/` | Publish through `publish-image-chart` (or the staging image workflow); make the Dockerfile cross-compile ([requirements](#dockerfile-requirements)) |
| 2 | **Hand-rolled build/push** — the caller builds or pushes an image or chart itself | `grep -rnE 'docker/build-push-action\|docker (build\|push)\|buildx (build\|imagetools)\|helm (package\|push)' .github/workflows/` | Publishing: the `main` template of your model. A PR-time image build: `image-check: true` in the PR suite |
| 3 | **Token as build-arg** — `CI_TOKEN`/`GH_TOKEN`/`NPM_TOKEN` handed to a build as an argument, or declared as `ARG`/`ENV` in a Dockerfile | `grep -rnE -A6 'build-args:\|--build-arg' .github/workflows/ \| grep -i token` and `find . -name 'Dockerfile*' -not -path './node_modules/*' -exec grep -nHE '^\s*(ARG\|ENV)\s+\S*TOKEN' {} +` | BuildKit secret `ci_token` and a `RUN --mount=type=secret,id=ci_token` ([requirements](#dockerfile-requirements)) |
| 4 | **SHA or `@main` pins** of this repo | `grep -rniE 'knkcs/workflows/[^ ]+@' .github/workflows/ \| grep -vE '@v1(\s\|$)'` | `@v1` ([policy](#pinning-v1-only)) |
| 5 | **Missing timeouts** — a job that runs steps without `timeout-minutes` (a `uses:` job cannot have one; its called jobs do) | `python3 -c "import glob,yaml;[print(f,j) for f in glob.glob('.github/workflows/*.y*ml') for j,s in (yaml.safe_load(open(f)).get('jobs') or {}).items() if 'uses' not in s and 'timeout-minutes' not in s]"` | `timeout-minutes:` on every such job: 10 for small jobs, the class defaults in the README for the rest |
| 6 | **No concurrency, or cancelling on `main`** | `grep -L '^concurrency:' .github/workflows/*.y*ml` and `grep -rn 'cancel-in-progress: true' .github/workflows/` | The templates' concurrency block, verbatim |
| 7 | **The PR suite again on `push: main`** — a `go-service-ci` call in a workflow triggered by `push` without `mode: merge-check` | `grep -ln 'go-service-ci' .github/workflows/* \| xargs grep -lE '^[[:space:]]*push:\|^on:.*push' \| xargs grep -L 'mode: merge-check'` | `pull_request` only in `ci.yml`; `main` runs the merge check from the `main` template |
| 8 | **Release not gated on the merge check** — a `release-please` call without `needs:` on the merge check, or in a workflow of its own | `grep -rn -B2 -A2 'release-please.yml@' .github/workflows/` and look for the `needs:` | The release `main` template |
| 9 | **Publishing from a tag-triggered workflow** that expects release-please's tags (they are created with `GITHUB_TOKEN` and trigger nothing) | `grep -rn -A3 'tags:' .github/workflows/` | Publish jobs gated on release-please's outputs in `main.yml` |
| 10 | **`CI_TOKEN` passed to release-please** (directly or by `secrets: inherit`) | `grep -rn -A4 'release-please.yml@' .github/workflows/ \| grep -E '^\S+-[0-9]+-\s*secrets:'` | No secrets on that job ([`CI_TOKEN`](#the-ci_token-secret)) |
| 11 | **Test-only inputs** in a caller | `grep -rnE 'test-changed-files\|test-soft-fail' .github/workflows/` | Delete them — they exist for this repo's self-test only |

## Adoption status

One row per active caller in both orgs, and per active repo that does not
adopt, with why. Read from each repo's default branch on **2026-09-30** (the
commit is next to the name); `v1` then pointed at `7d6dc74`, before the PR
suite / merge check rework. The migration tickets update their rows as they
land.

Columns: the **publish model** as the repo does it today; the shared
**workflows** and actions it uses; its **pin**; the **notes** list what is
hand-rolled and why, and what the anti-pattern checklist finds.

Not listed: repos with no workflows of their own and outside #21's analysis
(knkCS claude-agent-infra, author-portal), and repos with no push since early
August 2026 (knkCS image-to-formula, compare-xml, guardian*, reel,
doc-converter; knkcms knkcms-seed and the older repos).

### knkCS

| Repo | Publish model | Uses | Pin | Notes | Ticket |
|---|---|---|---|---|---|
| statushub (knkCS/statushub#76) | release (image + chart, UI package) | the caller templates: `ci.yml` (PR suite, with `ui-test`, `check-gofmt`, `image-check`), `commitlint.yml`, `main.yml` (merge check → `release-please` → `publish-image-chart` / `publish-ui`); `publish-image-chart` also by manual dispatch | `@v1` | Migrated by the pilot (#29), which observed every case end to end against `@main` of this repo. Both publish jobs build the release tag (`ref:`, #56 via knkCS/statushub#77 — needs `v1` at or past #56's merge, for `publish-ui`'s `ref` input). Nothing hand-rolled; secrets passed by name; the anti-pattern checklist finds nothing. | #29 (pilot), #56 |
| taskhub (knkCS/taskhub#478) | release (UI package) | the caller templates: `ci.yml` (PR suite, with `ui-lint`, `ui-test`, `check-gofmt`, `image-check`), `commitlint.yml`, `main.yml` (merge check + workspace scope check → `release-please` → `publish-ui`); actions `configure-private-modules`, `setup-go-node` for the scope check | `@v1` | Migrated by #32. The per-push `docker` job is gone — nothing consumed its image — so taskhub publishes no image or chart; the Dockerfile takes the token as the BuildKit secret `ci_token`, proven on each PR by `image-check`. `scope-check` (entscope) stays repo-specific: on PRs its own `scope-check.yml`, path-filtered to skip the docs change area so a docs-only PR runs only `changes` + `ci-ok`; on `main` a job in `main.yml` that gates `release-please` beside the merge check. The anti-pattern checklist finds nothing. | #32 |
| mediahub (knkCS/mediahub#229) | release (image + chart, UI package) | the caller templates: `ci.yml` (PR suite, with `ui-lint`, `ui-test`, `check-gofmt`, `image-check`), `commitlint.yml`, `main.yml` (merge check → `release-please` → `publish-image-chart` / `publish-ui`) | `@v1` | Migrated by #32. The hand-rolled QEMU `publish.yml` is gone: image (amd64 + arm64, each native) and chart are published by `publish-image-chart` from the release tag, so `:latest` is the newest release. release-please gained the root component (`v<version>` tags; changelog bootstrapped at `6e32f85`, first release 0.1.0 by a `Release-As` footer). The Dockerfile takes the token as the BuildKit secret `ci_token`, proven on each PR by `image-check`. Nothing hand-rolled; the anti-pattern checklist finds nothing. | #32 |
| flowhub (knkCS/flowhub#178) | UI package by hand-pushed `flowhub-ui-v*` tag; no release-please, no image publish (platform-deploy builds the image) | the caller templates: `ci.yml` (PR suite, with `ui-lint`, `ui-test`, `check-gofmt`, `image-check`), `commitlint.yml`, `main.yml` (the merge check alone); `publish-ui` from the tag-triggered `publish-flowhub-ui.yml` | `@v1` | Migrated by #33. The hand-rolled `image` job (every PR, no timeout) is now `image-check`, built only when the image area changes. `proto` (buf lint + gen drift — the shared workflow knows no buf) stays beside the shared call, with a timeout. `main.yml` has no release or publish jobs to gate: there is no release-please, and the UI publish stays tag-triggered because its tags are pushed by hand and so start it — the checklist's row 9 hit is that, by design. Secrets passed by name. A docs-only PR runs only `changes` and `ci-ok` of the shared suite, plus `proto`. | #33 |
| mailhub (knkCS/mailhub#73) | release (image + chart) | the caller templates: `ci.yml` (PR suite, with `check-gofmt`, `image-check`), `commitlint.yml`, `main.yml` (merge check → `release-please` → `publish-image-chart` from the release tag); `publish-image-chart` also by manual dispatch; actions `configure-private-modules`, `setup-go-node` | `@v1` | Migrated by #33, once its missing `CI_TOKEN` secret was added (#67; `main` had failed on credentials since September). The Dockerfile takes the token only as the BuildKit secret `ci_token` (it was `ARG GH_TOKEN`/`NPM_TOKEN`), for both the `@knkcms` npm packages and the private Go modules; `image-check` built it on the PR. The own `ui` job stays: the repo-root `.npmrc` reads `${NPM_TOKEN}`, which shadows the credential the shared `ui` job's `npm-github-packages` writes to `~/.npmrc`, so the shared `npm ci` would 401 (the build order is the same). The own `modules` job (gen/client dependency rule) stays. Both have timeouts. A docs-only PR runs only `changes` and `ci-ok` of the shared suite, plus the two own jobs. | #33 |
| messengerhub (knkCS/messengerhub#187) | release (image + chart, UI package) | the caller templates: `ci.yml` (PR suite, with `ui-test`, `image-check`), `commitlint.yml`, `main.yml` (merge check → `release-please` → `publish-image-chart` / `publish-ui`, each from its release tag); `publish-image-chart` also by manual dispatch | `@v1` | Migrated by #33. The UI package's suite moved to the shared `ui` job (`ui-test`); the own `frontend` job keeps root biome (the workspaces declare no `lint` script for `ui-lint`) and `web/`'s suite. `collisions` (duplicate proto field / migration numbers), `modules` (gen, client are separate modules) and `e2e-compiles` (e2e build tag) stay. All four have timeouts. Secrets passed by name. A docs-only PR runs only `changes` and `ci-ok` of the shared suite, plus the four own jobs. | #33 |
| authorhub (knkCS/authorhub#57) | release (image + chart, UI package) | the caller templates: `ci.yml` (PR suite, with `ui-test`, `npm-github-packages`, `image-check`), `commitlint.yml`, `main.yml` (merge check → `release-please` → `publish-image-chart` / `publish-ui`, both building the release tag); `publish-image-chart` also by manual dispatch | `@v1` | Repo-local jobs beside the `ci` job, each with a timeout: `collisions` (duplicate proto field / migration numbers), `modules` (the gen module, which the root `go test` never reaches) and `frontend` (root biome lint and web/'s suite — #19; the package's suite moved to `ui-test`). They are not gated by change areas, so a docs-only PR runs them beside `changes` and `ci-ok`. `publish-ui` cannot `npm ci` the @knkcms packages (#20), and no `NPM_TOKEN` secret is set. Secrets passed by name; the anti-pattern checklist finds nothing. | #34 |
| blueprinthub (knkCS/blueprinthub#149) | release (image + chart, UI package) | the caller templates: `ci.yml` (PR suite, with `ui-lint`, `ui-test`, `check-gofmt`, `npm-github-packages`, `image-check`), `commitlint.yml`, `main.yml` (merge check → `release-please` → `publish-image-chart` / `publish-ui`, both building the release tag); actions `configure-private-modules`, `setup-go-node` in its own jobs | `@v1` | SHA pin gone. Repo-local jobs beside the `ci` job, each with a timeout: `web-test` (`ui-test` covers `ui-package` only, #19), `scope-check` (entscope) and `gen-module`. They are not gated by change areas, so a docs-only PR runs them beside `changes` and `ci-ok`. `publish-ui` cannot `npm ci` the @knkcms package it needs (#20), and no `NPM_TOKEN` secret is set. Secrets passed by name; the anti-pattern checklist finds nothing. | #34 |
| versionkit (knkCS/versionkit#59) | release (Go module tag only) | the caller templates: `ci.yml` (PR suite, with `check-gofmt`, `check-ent-drift: false`), `commitlint.yml`, `main.yml` (merge check → `release-please`, no publish jobs) | `@v1` | Nothing hand-rolled. Secrets passed by name; the anti-pattern checklist finds nothing. | #34 |
| odon (`d44ba49`) | release (image + chart); UI package by hand-pushed `odon-ui-v*` tag | `release-please`, `publish-image-chart` | `@main` | `@main` left over from validating the native-arm build. Its PR checks are its own workflow (services-mode tests need env `go-service-ci` lacks), no concurrency or timeouts, full run on `push: main`. `publish-odon-ui.yml` is a hand-rolled tag-triggered npm publish that `publish-ui` could do. Its PR Test job's flaky `TestListMyDelegationGrants_ReturnsOwnGrants` (Postgres timestamp rounding) is fixed by knkCS/odon#263. | #35, #64 |
| fieldkit (`aaf9803`) | npm package (`@knkcs/fieldkit`) by hand-pushed `v*` tag; Go module in `go/` | `go-service-ci`, `commitlint`; action `configure-private-modules` | `@v1` | `go.yml` passes `working-directory`, which `v1` does not declare yet, so every Go run is a `startup_failure` until `v1` moves. Its module also needs private `knkcms/knkeditor/go`, outside the `GOPRIVATE=github.com/knkcs/*` the shared workflow sets. Own Node `ci.yml`, publish and Storybook workflows, none with timeouts. | #35 |
| commons (`250e08a`) | — (Go library) | nothing | — | No CI at all. | #35 |
| platform-deploy (`6987c6a`) | — (deploy repo) | `argocd-rendering-check` | `@v1` | Thin caller. No concurrency. | — |
| authorhub-deploy (`7972944`) | — (deploy repo) | `argocd-rendering-check` | `@v1` | Thin caller. No concurrency. | — |
| legalcitationhub (`ad4af44`) | — | `commitlint` | `@v1` | Commitlint only; no code CI yet. | — |
| contenthub (`3fa908f`) | — | `commitlint` | `@v1` | Commitlint only; no code CI yet. | — |
| showcase (`55d019f`) | — | nothing | — | Not a caller: Node/TypeScript. Own `check.yml`, with concurrency and a timeout. | — |
| anker (`38cfe5b`) | npm package by hand-pushed `v*` tag | nothing | — | Not a caller: Node/TypeScript library. Own CI, publish and Storybook workflows, no concurrency or timeouts. | — |
| skills (`ca67643`) | GitHub release by `v*` tag | nothing | — | Not a caller: Python. No concurrency or timeouts. | — |
| xmlmapper (`f9e8f53`) | release-please (Go module) | nothing | — | Not a caller yet: a Go library with its own CI and release-please, predating this repo and outside #21's analysis. No concurrency or timeouts; full run on `push: main`. | — |

### knkcms

| Repo | Publish model | Uses | Pin | Notes | Ticket |
|---|---|---|---|---|---|
| template (`e9add02`) | staging image (hand-rolled; shared `staging-image` planned, #31) + UI package via release-please | `publish-ui` (GitHub Packages) | `@v1` | `release.yaml` builds amd64 + arm64 cross-compiled on one runner (no QEMU since knkcms/template#232) with `GH_TOKEN`/`NPM_TOKEN` as build-args, then `update-staging` writes the SHA into knkcms/deploy; no timeouts. Own release-please job (custom outputs). Its specialised PR-only CI (change detection, `ci` verdict, concurrency, no timeouts) stays its own — out of #21's scope — and also passes the tokens as build-args. | #31 |
| core (`e5cc066`) | release (image + chart) | `release-please`, `publish-image-chart` | `@v1` | Specialised PR-only CI with concurrency, timeouts and a `ci` verdict stays its own (out of #21's scope); as it never runs on `main`, no `main`-scoped cache exists. Release not gated on a check, and `release-please` gets `secrets: inherit`. Commitlint inlined to relax `subject-case`, no timeout. `build.yml`: manual ACR build with `setup-qemu-action` (amd64 only). | — |
| layout (knkcms/layout#64) | staging image (image + chart); UI package by hand-pushed `layout-ui-v*` tag | the caller templates: `ci.yml` (PR suite, with `embed-frontend`, `frontend-build`, `check-gofmt`, `image-check`), `main.yml` (merge check → `staging-image`); action `configure-private-modules` | `@v1` | Migrated by #30, the staging image pilot. The QEMU `release.yaml` is gone: image (amd64 + arm64, each native) and chart are published by `staging-image` on every push to `main`, which then sets `image.tag` in knkcms/deploy's `environments/staging/services/layout-values.yaml`. The Dockerfile takes the token as the BuildKit secret `ci_token`, proven on each PR by `image-check`. Stay its own, with timeouts: `lint` (golangci-lint + buf lint, which the shared workflow runs neither of) and `layout-ui-package` (the npm package's contract, shell routes and an outside install); `publish-layout-ui.yaml` publishes the UI package to npmjs.org from a hand-pushed tag (not release-please's, so row 9 does not apply). The anti-pattern checklist finds nothing. | #30 |
| deploy (`8f7c4a5`) | — (deploy repo) | `argocd-rendering-check` | `@v1` | Own `core-services-values` validator job, no timeout. No concurrency. | — |
| knkeditor (`76946a0`) | npm packages via changesets | nothing | — | Not a caller: Node/TypeScript. Own CI and release, with concurrency, no timeouts. | — |
| knkcms-go (`94e5868`) | release-please (Go module) | nothing | — | Predates this repo: Go library with its own CI (commit check, lint, test, build) and release-please; no concurrency or timeouts. | — |
