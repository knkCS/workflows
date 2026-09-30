# knk CI platform

The shared GitHub Actions building blocks for the `knkCS` and `knkcms` orgs: how their repos are checked, released and published, and what that is allowed to cost.

## Language

### Images and platforms

**Deployment target**:
A CPU architecture that a deployed environment runs images on. Today only `linux/amd64`.
_Avoid_: prod arch, server arch

**Developer platform**:
A CPU architecture that every published image must include so developers can run it locally, without anything being deployed on it. Today `linux/arm64` (Apple Silicon, local k3d).
_Avoid_: secondary arch, optional arch

**Native build**:
Producing an image variant without emulation — by cross-compiling from the build host's own architecture, or on a runner of the target architecture.
_Avoid_: multi-arch build (says nothing about how)

**Emulated build**:
Producing an image variant by running the other architecture's binaries under QEMU. Not allowed.

### Checks

**PR suite**:
The full set of checks a pull request must pass — including the containerised tests — run against the PR merged with `main` as it was when the run started.
_Avoid_: CI (ambiguous), full CI

**Merge check**:
The light, compile-level check run on every push to `main` after a merge: vet, UI build and typecheck, no containerised tests. It exists to catch two individually green PRs that do not compile together.
_Avoid_: main CI, post-merge CI

**Change area**:
One of the parts of a repo a pull request can touch — **docs**, **Go**, **UI**, **image** (the Dockerfile and its build inputs) — used to decide which checks the PR suite needs. A file that belongs to no known area counts as every area.
_Avoid_: path filter (that is the mechanism, not the concept)

**Suite verdict**:
The single always-running result of a PR suite, green only if every check that ran passed and none was wrongly skipped. The only check branch protection should require.
_Avoid_: required check, status check

### Publishing

**Release**:
A versioned publication of a repo's image, chart or package, cut when a release-please PR merges. The knkCS publish model.
_Avoid_: deploy, publish (too broad)

**Staging image**:
An image tagged with the commit SHA, built on every push to `main` and written into the deploy repo's staging values, so staging follows `main`. The knkcms publish model.
_Avoid_: nightly, snapshot, latest

### Adoption

**Caller**:
A repo that uses this repo's reusable workflows or actions.
_Avoid_: consumer, client repo

**Caller template**:
A ready-to-copy workflow file in this repo that shows a caller the whole intended wiring for one publish model — triggers, concurrency, which reusable workflows to call and in what order.
_Avoid_: example, starter workflow
