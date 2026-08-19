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
| `publish-ui.yml` | Publish a UI npm package to GitHub Packages |

### `go-service-ci.yml` inputs

| Input | Type | Default | Effect |
|---|---|---|---|
| `go-version-file` | string | `go.mod` | File `setup-go` reads the toolchain version from |
| `test-mode` | string | `testcontainers` | `testcontainers` (Docker-in-job) or `services` (Postgres + Redis service containers) |
| `test-timeout` | string | `30m` | `go test -timeout`. Explicit because Go's default is 600s **per package** |
| `embed-frontend` | boolean | `false` | Write a `web/dist/index.html` stub so a `go:embed` compiles in the Go jobs |
| `frontend-build` | boolean | `false` | Build the `web` workspace in the `ui` job — and, with `ui-lint`, lint it too |
| `ui-package` | string | `""` | Workspace to build and typecheck. **Empty means the `ui` job does not run at all** |
| `ui-lint` | boolean | `false` | Run `ui-package`'s own `lint` script — and `web`'s when `frontend-build` is on |
| `ui-test` | boolean | `false` | Run `ui-package`'s own `test` script |
| `helm-chart` | string | `""` | Chart path to `helm lint`. Empty means the `helm` job does not run |
| `node-ci-flags` | string | `""` | Extra flags for `npm ci` (e.g. `--legacy-peer-deps`) |
| `npm-github-packages` | boolean | `false` | Authenticate `npm ci` to `npm.pkg.github.com` with `CI_TOKEN` in the `ui` job |
| `check-ent-drift` | boolean | `true` | Regenerate `internal/ent` and fail if `internal/ent/db` drifts |
| `check-gofmt` | boolean | `false` | Fail the `backend` job if any **tracked** Go file is not gofmt-clean |

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
  setting either without it is refused loudly in the `backend` job instead of
  being silently ignored.
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
