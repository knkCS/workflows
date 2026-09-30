# knkCS stays on the Free plan, so its checks are advisory

GitHub Free allows no branch protection or rulesets on private repos, so in knkCS nothing stops a red PR from merging or requires a branch to be up to date with `main`. Moving to Team (~$8/month for two seats, partly offset by 1,000 more included minutes) would let the suite verdict be a required check; we chose not to, to keep Actions spend flat. The consequence is that on knkCS the merge check on `main` is the only safety net, and it gates releases — revisit this decision if broken `main` builds start to recur.
