---
name: maintain-env-sync
description: Use when the local environment has drifted from the repository's default branch — after merging a pull request, after pulling changes, or when an installed dependency version no longer matches what the manifest pins. Fast-forwards the default branch and reinstalls only what actually changed, into the real environment. Use when the user says their venv is out of date, a package version looks wrong, or asks to sync after a merge.
---

# Environment sync

Brings the working checkout and its installed dependencies back in line with the default
branch. Two steps: fast-forward the branch, then install what the manifest diff says
changed.

## Overlay during review, real install after merge

The review gate is forbidden from installing into the user's environment. A pull request's
dependency is speculative — installing it would leave the machine running something that
may never land, silently so if the merge is declined. Hence the `PYTHONPATH` overlay in
`verify-runner`.

**After** the merge that inverts. The default branch now pins the new version, so an
environment still holding the old one is not "safe", it is *wrong*: the next test run, the
next debugging session and the next review all happen against something the repository does
not describe. That drift is the bug this skill exists to close.

Same operation, opposite correct answer, decided entirely by which side of the merge you
are on. Do not carry the review gate's caution across that line.

## Preconditions — refuse rather than surprise

`scripts/sync-env.sh` checks these and stops with a reason rather than proceeding:

- **Tracked files modified.** Never pull over uncommitted work. Untracked files are fine.
- **Mid-merge, rebase or cherry-pick.** Finish it first.
- **Not on the default branch.** Report and stop. Silently switching someone off a feature
  branch loses their place. `--allow-branch-switch` opts in.
- **Pull would not fast-forward.** Use `--ff-only` and report; never create a merge commit
  or rewrite history to make a sync work.

## Install only what changed

Diff the manifests between the old and new HEAD. If no manifest changed, there is nothing
to install — say so and stop. Reinstalling an entire environment on every merge turns a
two-second operation into minutes and trains people to skip it.

For the per-stack commands and how to diff a manifest, LOAD `references/sync-strategies.md`.

## Verify, do not assume

An install that prints success can still leave the old version importable — a stale
`.pth`, a shadowing directory, a user-site install ahead of the venv. So after installing,
**assert** the runtime actually resolves the pinned version:

```bash
<py> -c "import pypdf; print(pypdf.__version__)"   # must equal the pin
<py> -m pip check                                   # and nothing else broke
```

Report a table of before → after → pinned. If any row disagrees, that is a failure worth
surfacing, not a rounding error.

## Reporting

Say what moved: commits pulled, packages changed with old and new versions, and anything
still mismatched. If nothing needed doing, say that in one line — a sync that reports at
length about having done nothing is noise.
