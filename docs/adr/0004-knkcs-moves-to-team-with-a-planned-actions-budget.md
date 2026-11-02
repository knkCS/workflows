# knkCS moves to Team, with a planned Actions budget

Supersedes [ADR 0002](0002-knkcs-stays-on-free-without-enforced-checks.md).

In September and October 2026, knkCS used about 9,600–9,900 Actions minutes against the Free plan's 2,000. Both months it ran into its $40 budget mid-month, and private-repo CI stopped until the 1st (from Oct 17 in October); knkcms ran out of its 3,000 included minutes on Oct 19 the same way. Removing per-job overhead and per-test containers cuts the demand by roughly a third, but knkCS still needs about 8,000 minutes a month, so staying on Free means paying overage anyway. Team costs about $8/month for two seats and includes 1,000 more minutes (worth about $6), so its net cost is about $2/month, and it makes the suite verdict enforceable as a required check. ADR 0002 traded enforced checks for flat spend; at a net $2 that trade no longer holds. knkCS therefore moves to Team, its suite verdict becomes the required check on every repo whose PR suite produces one, and its budget is set with headroom (about $60) above the expected overage, so CI does not stop mid-month.

## Considered Options

- **Stay on Free and raise the budget.** Pays the same overage and leaves every check advisory.
- **Self-hosted runners for the heavy test jobs.** Possibly cheaper per minute, but it adds runner infrastructure to operate, and GitHub's announced platform fee for self-hosted runners was not verified. Revisit if knkCS demand keeps growing after the savings land.

## Consequences

- An early-warning report projects month-end usage for both orgs, so a budget is never reached unnoticed again.
- A red PR suite, including a commit-message lint failure, now blocks a merge on knkCS.
