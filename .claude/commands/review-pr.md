---
argument-hint: <pr-number> [--dry-run]
description: Review a pull request and post a verdict comment saying whether it is
  safe to merge.
---

Review pull request $ARGUMENTS in this repository.

Use the `review-pr-gate` skill and follow it exactly. In brief:

1. Run `scripts/pr-context.sh` for the PR number to gather facts from the GitHub REST API.
2. Apply the trust gate before executing anything from the PR.
3. Route to the `dependency-bump` or `code-change` lane.
4. Dispatch `evidence-ladder-runner`, `unit-test-runner`, and (code-change lane only)
   `pr-risk-reviewer` as subagents, in parallel where they are independent.
5. Derive the verdict per the `shipyard-contracts` schema.
6. Edit the existing verdict comment, or create one if none exists.

If `--dry-run` appears in the arguments, render the comment to the terminal and post
nothing.

Do not merge, approve, or close anything. This command only reviews and reports — merging
is `/merge-pr`, deliberately separate.