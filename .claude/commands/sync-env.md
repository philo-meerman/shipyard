---
argument-hint: '[--dry-run] [--allow-branch-switch]'
description: Bring the local checkout and its installed dependencies in line with
  the default branch.
---

Sync this repository's local environment with its default branch. $ARGUMENTS

Use the `maintain-env-sync` skill. In brief: run `scripts/sync-env.sh` with any arguments
given, then report what moved — commits pulled, packages changed old → new, and anything
still mismatched after the install.

If the script refuses a precondition, relay the reason and stop. Do not stash the user's
changes, switch their branch, or force a non-fast-forward pull to make the sync succeed.