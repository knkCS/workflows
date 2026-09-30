# CLAUDE.md

## Adopting these workflows

To make a repo use this repo's workflows — or to audit one that does — follow
[`docs/adopting.md`](docs/adopting.md): copy the caller templates from
`templates/`, check the repo against the anti-pattern checklist, and update
the adoption status table there when a caller changes. A change to a shared
workflow's inputs must keep `templates/` in step (`tests/caller-templates/run.sh`
fails otherwise).

## Agent skills

### Issue tracker

Issues live in GitHub Issues for knkCS/workflows, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
