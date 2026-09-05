# The eight preconditions

Each gate, what it checks, and the failure it exists to prevent. A gate you do not
understand is a gate someone will disable.

## 1 — Exactly one parseable verdict

Find comments containing `shipyard:verdict`. Require exactly one, whose payload parses as
JSON with `schema == "shipyard/verdict/v1"`.

*Prevents:* acting on a half-written comment, on an older schema whose fields mean something
different, or picking arbitrarily between two verdicts. Two verdict comments usually means
one was posted by hand — precisely the case where guessing is worst.

## 2 — `verdict == "APPROVE"`

`BLOCK` and `NEEDS_HUMAN` never merge. Neither does any unrecognised value.

*Prevents:* merging a change the reviewer declined to endorse.

## 3 — Comment author is the authenticated user

Compare the comment's author to `gh api user --jq .login`.

*Prevents:* a verdict written by anyone else being treated as your own review. This is the
weakest gate — anyone with write access can post as themselves, and if that is *you*, this
gate passes. That is exactly why gates 4–7 re-verify everything independently rather than
trusting the payload.

## 4 — Head SHA matches

`payload.head_sha` must equal the live `head.sha`.

*Prevents:* the most dangerous case — a PR reviewed clean, then new commits pushed, then
merged on the strength of the old review. This gate is why the review records the SHA at
all.

## 5 — Live checks

Re-read the check rollup now; do not trust the payload's copy.

- Failing required check → abort.
- Any check still `IN_PROGRESS`/`QUEUED` → abort as "pending", not as failure.
- `SUCCESS`, `NEUTRAL`, `SKIPPED` all pass.

`NEUTRAL` is what CodeQL reports when it has nothing to say. Treating it as failure blocks
every PR in a repo with code scanning enabled — a common and very confusing self-inflicted
outage.

## 6 — Mergeability, two-phase

**Pre-approval:** accept `mergeable_state: "blocked"` when `mergeable == true` and the only
missing requirement is the approving review. Abort on `dirty` — that is a real conflict.

**Post-approval:** re-read and require `clean` or `has_hooks`.

*Prevents:* two opposite mistakes. Merging into a conflicted branch, and — the one the first
draft of this design got wrong — aborting on `blocked` when `blocked` is the normal state of
a PR that has not yet been approved. A branch ruleset requiring one approving review puts
every PR in `blocked` until the moment you approve it.

## 7 — Review state and draft

No review in state `CHANGES_REQUESTED`. PR not a draft.

*Prevents:* overriding a human who explicitly asked for changes, and landing work its author
has marked unfinished. A dismissed or superseded `CHANGES_REQUESTED` still counts — resolve
it on GitHub, not here.

## 8 — Repository policy

From `.shipyard.yml`:

- `auto_merge: false` → stop and hand back to the user. The per-repo off switch.
- For the dependency lane, `dependency.update_type` must be in
  `dependency_policy.auto_merge_update_types` (default `[patch, minor]`). **`major` and
  `unknown` never auto-merge.**
- If `dependency_policy.behaviour_diff: block` and the payload has `evidence.rung3 == "diff"`
  → stop.

*Prevents:* a policy chosen once from being silently outgrown. Major bumps are where
breaking changes live by definition; a gate that cannot tell major from patch is not a
policy.

## The pass marker

On a clean sweep, `preflight.sh` writes `.git/shipyard/<pr>-<head_sha>.pass`, valid for ten
minutes. The `merge-guard` hook requires it before allowing any `gh pr merge`.

`.git/` is never committed and is per-clone, so a marker cannot travel with the repository
or be created by a PR. Keying it to the head SHA means a marker cannot survive a push, and
the ten-minute expiry means it cannot survive a long detour.
