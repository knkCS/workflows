# knkcs/workflows

Public home for the knk organizations' **reusable GitHub Actions workflows** and
**composite actions**, shared across the `knkcs` and `knkcms` orgs. Public so that
repos in either org can reference them on the GitHub free tier (private
cross-org reuse requires Enterprise).

These workflows contain **no secrets** — callers pass tokens (e.g. `CI_TOKEN`)
via `secrets:` / `secrets: inherit` at call time.

## Reusable workflows (`.github/workflows/`)

| Workflow | Purpose |
|---|---|
| `go-service-ci.yml` | Go service CI (vet, test, lint) |
| `commitlint.yml` | Conventional-commit linting |
| `release-please.yml` | release-please PR + release automation |
| `publish-image-chart.yml` | Build+push image and Helm chart to GHCR |
| `publish-ui.yml` | Publish a UI npm package to a configurable registry (public npm or GitHub Packages) |
| `argocd-rendering-check.yml` | Render a deploy repo's ArgoCD Applications with their real value files and schema-validate the output |

`self-test.yml` is not reusable: it is this repo's own CI. On every PR that
touches a workflow, a script or a test it runs actionlint over every workflow
(configured by `.github/actionlint.yaml`), `tests/workflow-timeouts/run.sh`
(every job declares the agreed timeout), and each engine script's fixture
self-test (`tests/rendering-check/run.sh`, `tests/change-areas/run.sh`). It
also calls `go-service-ci.yml` from the PR's own commit with four fixed change
sets — docs-only, Go-only (in both test modes) and UI-only — against the
fixtures in `tests/go-service-ci/`, and checks that each ran exactly the jobs
its change areas need. The root `package.json` exists only for that UI
fixture.

### Job timeouts

Every job in every shared workflow declares `timeout-minutes`, so a hang costs
minutes rather than GitHub's 6-hour job limit (in September 2026 seven hung
image builds burned ~2,500 minutes that way). Defaults are 40 minutes for Go
tests, 30 per image build leg, 15 for UI, and 10 for everything else. Where a
slow but healthy run is plausible, a caller can raise the timeout with a
`number` input; the other jobs are fixed at 10:

| Workflow | Input | Default | Jobs it bounds |
|---|---|---|---|
| `go-service-ci.yml` | `test-timeout-minutes` | `40` | `go` |
| `go-service-ci.yml` | `ui-timeout-minutes` | `15` | `ui` |
| `publish-image-chart.yml` | `build-timeout-minutes` | `30` | each `build` leg (amd64, arm64) |
| `publish-ui.yml` | `ui-timeout-minutes` | `15` | `publish` |
| `argocd-rendering-check.yml` | `render-timeout-minutes` | `10` | `render` |

Fixed at 10: `go-service-ci`'s `changes` and `ci-ok`, `publish-image-chart`'s
`merge`, `commitlint`, `release-please`. In `go-service-ci`, the `go` job's
40 minutes sits above the 30m `test-timeout` so that `go test`'s own timeout,
with its stack dump, fires first — raise the two together.

### `go-service-ci.yml`: change areas and the suite verdict

Every run starts with a `changes` job that classifies the pull request's changed
files into **change areas** — docs, Go, UI, image — and ends with `ci-ok`, the
**suite verdict**.

- **Each PR runs only the jobs its change areas need.** The `go` job runs
  when the Go area changed, the `ui` job when the UI area did (and a
  `ui-package` is set). So a UI-only PR skips the Go suite, a Go-only PR skips
  `npm ci` and the UI build, and a docs-only PR runs only `changes` and
  `ci-ok`, green. (An image-only PR also runs neither: no job here builds the
  image yet.)
- **One Go job.** `go` runs every Go check on one runner — ent drift, gofmt,
  vet and helm lint first, so they fail within about a minute, then the
  tests — so Go setup and the module download happen once. Both test modes
  are this job: in `services` mode it also starts the Postgres and Redis
  service containers, in `testcontainers` mode it starts none. (It replaces
  the former `backend`, `test-testcontainers`, `test-services` and `helm`
  jobs.)
- **`ci-ok` is the one check to require** in branch protection (where the plan
  allows it — see ADR 0002). It always runs, is red if any job that ran failed
  or was cancelled, and is green when jobs were skipped by change detection. In
  the checks list it appears under the caller's job name, e.g. `ci / ci-ok`.
  Do not require the individual jobs instead: GitHub reports a skipped job to
  branch protection as passing, whether change detection skipped it or a
  failure upstream did, so only `ci-ok` knows which skip was legitimate.
- **The file list comes from the API**, not a checkout, so no deep fetch. A
  renamed file counts under both its old and its new path. A non-PR event
  (push, `workflow_dispatch`) means every area.
- **Your layout counts.** Everything under `working-directory` and
  `helm-chart` is Go, and everything under `ui-package` is UI — Markdown,
  Dockerfiles and `*.go` files excepted, which keep their own area. So a Go
  module in `go/`, a chart change or a UI package outside `packages/` does not
  run every job.
- **When in doubt, every area.** A file in no known area — a Makefile, a
  workflow, a chart that is not `helm-chart`, anything under `.claude/` —
  turns on every area, as does
  an empty or truncated (300+ files) change set. Change detection can only ever
  run too much, never too little.

What counts as **docs**: `**/*.md`, `docs/**`, `.scratch/**`, licence files (`LICENSE`, `LICENSE.txt`, `LICENSE-MIT`, …), issue
and PR templates under `.github/`, and `.release-please-manifest.json`. Never
docs, whatever the extension: `**/testdata/**`, `**/fixtures/**`,
`**/__fixtures__/**`, and anything matching the `docs-exclude` input — a
whitespace- or newline-separated list of shell globs over the whole path, where
`*` crosses `/`. Use it for Markdown that is really an input to code:

```yaml
    with:
      docs-exclude: |
        prompts/*
        internal/templates/*.md
```

The full rules (Go, UI, image) are in the header of `scripts/change-areas.sh`,
the classifier; its fixture self-test is `tests/change-areas/run.sh`.

### `go-service-ci.yml` inputs

| Input | Type | Default | Effect |
|---|---|---|---|
| `go-version-file` | string | `go.mod` | File `setup-go` reads the toolchain version from |
| `test-mode` | string | `testcontainers` | `testcontainers` (Docker-in-job) or `services` (Postgres + Redis service containers) |
| `test-timeout` | string | `30m` | `go test -timeout`. Explicit because Go's default is 600s **per package** |
| `embed-frontend` | boolean | `false` | Write a `web/dist/index.html` stub (under `working-directory`) so a `go:embed` compiles in the `go` job |
| `frontend-build` | boolean | `false` | Build the `web` workspace in the `ui` job — and, with `ui-lint`, lint it too |
| `ui-package` | string | `""` | Workspace to build and typecheck. **Empty means the `ui` job does not run at all** |
| `ui-lint` | boolean | `false` | Run `ui-package`'s own `lint` script — and `web`'s when `frontend-build` is on |
| `ui-test` | boolean | `false` | Run `ui-package`'s own `test` script |
| `helm-chart` | string | `""` | Chart path to `helm lint` in the `go` job, relative to the repo root. Empty means no helm lint |
| `node-ci-flags` | string | `""` | Extra flags for `npm ci` (e.g. `--legacy-peer-deps`) |
| `npm-github-packages` | boolean | `false` | Authenticate `npm ci` to `npm.pkg.github.com` with `CI_TOKEN` in the `ui` job |
| `check-ent-drift` | boolean | `true` | Regenerate `internal/ent` and fail if `internal/ent/db` drifts |
| `check-gofmt` | boolean | `false` | Fail the `go` job if any **tracked** Go file under `working-directory` is not gofmt-clean |
| `runs-on` | string | `ubuntu-latest` | Runner label for the `go` job (the other jobs stay on `ubuntu-latest`). `services` mode needs a Linux runner with Docker |
| `working-directory` | string | `.` | Where the Go module lives, relative to the repo root (e.g. `go`). Every command of the `go` job runs there; `go-version-file` and `helm-chart` stay root-relative, so pass e.g. `go-version-file: go/go.mod` too |
| `test-timeout-minutes` | number | `40` | Job timeout for the `go` job; keep it above `test-timeout` (see [Job timeouts](#job-timeouts)) |
| `ui-timeout-minutes` | number | `15` | Job timeout for the `ui` job |
| `docs-exclude` | string | `""` | Extra paths that are never docs (see [change areas](#go-service-ciyml-change-areas-and-the-suite-verdict)) |
| `test-changed-files` | string | `""` | **Test-only**, for this repo's self-test: replaces the PR's changed-file list. Callers never set it |

`check-gofmt`, `ui-lint`, `ui-test` and `npm-github-packages` are opt-in and
default to off, so enabling them is always a deliberate change to a caller's CI.
Four things to know before turning them on:

- **`check-gofmt` checks tracked files and fails on an unparseable one.** It lists
  them with `git ls-files`, so `node_modules/` and any other worktrees in the
  checkout are not reported as this tree's drift, and it fails on a non-zero exit
  rather than only on a non-empty list. Nothing is excluded, generated code
  included — if it fires on generated output, regenerate rather than hand-format.
- **The two UI gates cover different workspaces.** `ui-lint` covers `ui-package`
  and, when `frontend-build` is on, `web`; `ui-test` covers `ui-package` alone,
  because an embedded `web` host is a thin shell — keep its suite in a job of your
  own beside the shared call if you want one. Each covered workspace **must
  declare the script**: `npm run -w <workspace> <script>` fails on a missing one
  rather than skipping it.
- **`ui-lint` and `ui-test` require `ui-package`.** The `ui` job runs only when one is set, so
  setting either without it is refused loudly in the `changes` job — on every
  run, whatever the PR touches — instead of being silently ignored.
- **`npm-github-packages` writes only the credential.** Before `npm ci`, the
  `ui` job appends `//npm.pkg.github.com/:_authToken=<CI_TOKEN>` to the runner's
  `~/.npmrc` — GitHub Packages rejects installs without a token, even for public
  packages. The scope→registry mapping (e.g.
  `@knkcms:registry=https://npm.pkg.github.com`) belongs in the **caller's
  committed `.npmrc`**; without it the token is never consulted, and with it but
  without this input, `npm ci` fails with a 401. `CI_TOKEN` must carry
  `read:packages` for the scopes the lockfile pulls. Without `ui-package` the
  input is inert — no job runs `npm ci` — and unlike the gates above it is not
  refused: an unused credential misleads no one, where a skipped gate lies.

### `argocd-rendering-check.yml` inputs

For GitOps deploy repos (knkcms/deploy is the canonical layout). On every PR it
expands each ApplicationSet's generators, renders every generated Application
with `helm template` over its declared sources — service-repo git charts,
upstream Helm/OCI charts, and charts held in the deploy repo — feeding in the
real value files (`$ref/...` entries resolve through the PR's checkout), then
schema-validates the rendered manifests with kubeconform. A values typo, a
missing value file, or a render that breaks the Kubernetes schema fails the
check before ArgoCD ever sees the commit.

| Input | Type | Default | Effect |
|---|---|---|---|
| `argocd-dir` | string | `argocd` | Directory scanned (recursively) for Application/ApplicationSet documents |
| `skip-environments` | string | `""` | Comma/space-separated `environment` generator params to skip — the knob for environments declared unwired |
| `kubernetes-version` | string | `1.31.0` | Passed to `helm template --kube-version` and `kubeconform -kubernetes-version` |
| `kubeconform-flags` | string | `-strict -ignore-missing-schemas` | Extra kubeconform flags (e.g. add a CRD schema location) |
| `kubeconform-version` | string | `0.6.7` | kubeconform release installed (static binary, no leading `v`) |
| `render-timeout-minutes` | number | `10` | Job timeout; raise for a deploy repo with many Applications |

`CI_TOKEN` must carry read access to every private service repo the
ApplicationSets pull charts from. A thin caller:

```yaml
jobs:
  rendering-check:
    uses: knkcs/workflows/.github/workflows/argocd-rendering-check.yml@v1
    secrets:
      CI_TOKEN: ${{ secrets.CI_TOKEN }}
```

The engine is `scripts/argocd-rendering-check.py`; its module comment is the
reference for the exact source shapes and semantics. Its fixture self-test
(`tests/rendering-check/run.sh`, run by `self-test.yml`) proves the check green
on a correct layout and red on a missing value file and on a schema-breaking
values typo.

## Composite actions (`actions/`)

| Action | Purpose |
|---|---|
| `configure-private-modules` | GOPRIVATE + git insteadOf for private module fetch |
| `setup-go-node` | setup-go (+ optional setup-node) with caching |

## Versioning

Pin `@v1`. `v1` is a **moving major-version tag** — it advances on
backward-compatible changes; breaking changes will introduce `v2`.

## Usage

```yaml
jobs:
  publish:
    uses: knkcs/workflows/.github/workflows/publish-image-chart.yml@v1
    with:
      chart-path: charts/<name>
      chart-name: <name>
      version: ${{ needs.release-please.outputs... }}
    secrets:
      CI_TOKEN: ${{ secrets.CI_TOKEN }}
```
