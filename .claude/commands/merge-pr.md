---
argument-hint: <pr-number> [--dry-run]
description: Re-verify a shipyard verdict against live GitHub state, then approve
  and merge the pull request.
---

Merge pull request $ARGUMENTS in this repository.

Use the `review-pr-merge` skill and follow it exactly. In brief:

1. Run `scripts/preflight.sh <number>` (phase `pre`) to evaluate all eight preconditions
   against live GitHub state. The verdict comment is a cache, not permission.
2. If any gate fails, report which one, what was expected, what was found, and stop.
   Do not work around it.
3. Approve with `gh pr review --approve`, unless the PR author is the authenticated user —
   GitHub rejects self-approval, so skip it and record that you did.
4. Re-run `scripts/preflight.sh <number> --phase post`, which requires a clean mergeable
   state and writes the pass marker the merge-guard hook checks for.
5. Merge with the configured method, then report what merged, at which SHA, whether
   approval was given or skipped, and any `follow_ups` from the verdict payload.

If `--dry-run` appears in the arguments, run phase `pre` only, report the gate-by-gate
result, and stop without approving or merging.