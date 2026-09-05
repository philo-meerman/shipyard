---
name: review-pr-merge
description: Use when acting on a shipyard verdict to land a pull request — the user asks to merge a PR, approve and merge it, or land a reviewed dependabot bump. Re-verifies the verdict against live GitHub state through eight preconditions, then approves and merges. Refuses when the verdict is stale, forged, missing, or when repository policy withholds auto-merge. Never merges a PR it has not verified itself.
---

# PR merge gate

Lands a pull request that `review-pr-gate` has already reviewed. Every gate below must pass;
any failure aborts with the reason named and **nothing mutated**.

Load the `shipyard-contracts` skill for the verdict schema before parsing anything.

## Invocation

`/merge-pr <number> [--dry-run]`. `--dry-run` reports the gate-by-gate result and stops.

## The verdict is a cache, never an authority

The verdict comment was written by a GitHub account, and any account with write access can
write the same comment by hand. So it is a starting point, not permission. Every fact it
asserts — head SHA, checks, mergeability, review state — is **re-read live** and the live
value wins.

If you ever find yourself merging because the comment said `APPROVE`, without having
re-verified, you have misunderstood this skill.

## The eight gates

Run `scripts/preflight.sh <number>`, which evaluates all of them and writes the pass marker
only on a clean sweep. LOAD `references/preconditions.md` for what each gate means and why
it exists.

1. Exactly one parseable `shipyard:verdict` comment, schema `shipyard/verdict/v1`.
2. `verdict == "APPROVE"`.
3. Comment author is the authenticated user.
4. `head_sha` in the payload equals the live head — no commits since review.
5. Live checks: none failing, none pending.
6. Mergeability, in **two phases** — see below.
7. No `CHANGES_REQUESTED` review; PR not draft.
8. Repository policy in `.shipyard.yml` permits it.

## Gate 6 is two-phase, and this matters

A PR awaiting its first approval reports `mergeable_state: "blocked"`. That state means
"needs the approval we are about to give" — not "unmergeable".

- **Before approving:** accept `blocked` when the only thing missing is the review. Abort
  on `dirty` (conflicts), always.
- **After approving:** re-read `mergeable_state` and require `clean` (or `has_hooks`)
  before calling merge.

Checking `blocked` before approving and aborting on it kills exactly the PRs this gate
exists to land. Do not collapse the two phases.

## Run the mutating commands bare, one at a time

`gh pr review --approve` and `gh pr merge` must each be issued as a **single, unchained
command** — no `&&`, no pipes, no `echo` alongside them, no wrapping in a loop.

Permission layers match allowlist rules against a command prefix. A compound line that
bundles the merge with other statements does not match `Bash(gh pr merge:*)`, falls through
to a classifier that judges the line as a whole, and gets refused — even in a repository
where the rule is already granted. The refusal looks like a capability problem and is
really a command-shape problem.

Same reason you should not pipe them through `tail` to trim the output. Run the command,
read what it prints, then run the next one.

## Approving

`gh pr review --approve` — **unless the PR author is the authenticated user**. GitHub
rejects self-approval, and treating that rejection as a gate failure would block every PR
you opened yourself. Detect it up front (`author.login == gh api user --jq .login`), skip
the approval, record that you skipped it and why, and proceed to merge.

## Merging

`gh pr merge <n>` with `--squash` (or `merge_method` from `.shipyard.yml`) and
`--delete-branch` unless `delete_branch: false`.

After merging, report: what was merged, at which SHA, whether approval was given or skipped,
and **any `follow_ups` from the verdict payload**. Follow-ups are things the merge does not
do — regenerating a derived artefact, updating a lockfile elsewhere. Surfacing them at merge
time is the last moment anyone will look.

## When a gate fails

Say which gate, what was expected, what was found, and what would fix it. Then stop. Do not
offer to force, do not retry with different flags, and do not merge by another route — the
`merge-guard` hook will block that anyway, and working around your own gate defeats the
purpose.

If the failure is gate 1 with *two* verdict comments, that is a contract violation. Refuse
and say so rather than picking one; a duplicate verdict usually means someone posted one by
hand.
