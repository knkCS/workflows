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
