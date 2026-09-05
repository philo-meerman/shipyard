# Stage map

`shipyard` is organised around the software delivery lifecycle. Each package belongs to
exactly one stage, and the stage is encoded in the package name so install refs are
self-describing:

```
apm install philo-meerman/shipyard/packages/review-pr-gate#v0.1.0 --target claude
```

## The eight stages

| Stage | Prefix | Question it answers | Shipped |
|-------|--------|---------------------|---------|
| Intake | `intake-` | Is this worth doing, and what is actually being asked? | — |
| Refine | `refine-` | Is it specified well enough to build? | — |
| Design | `design-` | What shape should the solution take? | — |
| Build | `build-` | Is it implemented well? | — |
| Review | `review-` | Is it safe to land? | **v0.1.0** |
| Test | `test-`, `verify-` | Does it actually work? | **v0.1.0** |
| Deploy | `deploy-` | Can it ship, and did it? | — |
| Maintain | `maintain-` | Is it still healthy? | — |

Cross-stage packages carry the `shipyard-` prefix (e.g. `shipyard-contracts`) and hold
schemas and conventions that more than one stage depends on.

## Shipped in v0.1.0

- **`shipyard-contracts`** — cross-stage. The verdict schema and comment template that the
  review and merge gates both read.
- **`verify-runner`** — *test*. The evidence ladder (resolves → imports → smoke → boundary
  diff) plus the repo's own unit suite. Usable standalone: "run this repo's tests".
- **`review-pr-gate`** — *review*. Reviews a PR, routes it to a lane, gathers evidence,
  posts a verdict comment.
- **`review-pr-merge`** — *review*. Re-verifies the verdict against live GitHub state and
  approves + merges. Ships a `PreToolUse` hook that blocks ungated merges.
- **`bundles/pr-flow`** — a manifest-only package depending on both gates, so a repo gets
  the whole PR flow in one install.

## Planned

Named here so later work has an obvious home; nothing below exists yet.

- `intake-issue-shaper` — turn a vague request into a well-formed issue.
- `refine-spec-writer` — issue to spec, with acceptance criteria.
- `design-adr` — architecture decision records with trade-offs.
- `build-tdd` — red/green/refactor loop enforcement.
- `deploy-preflight` — release readiness checks.
- `maintain-dep-triage` — batch triage of dependency and security alerts.

## Adding a package

See [authoring.md](authoring.md).
