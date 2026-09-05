# shipyard

SDLC agent packages for [Claude Code](https://claude.com/claude-code), distributed with
[APM](https://github.com/microsoft/apm).

Declare what you want in a repository's `apm.yml`, run `apm install`, and that repository
gets the capability — pinned by commit and content hash, committed alongside the code, the
same for every clone. Not global config on one laptop.

v0.1.0 ships the **pull request flow**: a gate that reviews a PR and posts a verdict, and a
gate that acts on that verdict to approve and merge. See [docs/stages.md](docs/stages.md)
for how the rest of the lifecycle is laid out.

## Install

The whole PR flow:

```bash
apm install philo-meerman/shipyard/packages/bundles/pr-flow#v0.1.0 --target claude
```

Or à la carte — a repo that should get reviews but must never merge on its own installs
only the reviewer:

```bash
apm install philo-meerman/shipyard/packages/review-pr-gate#v0.1.0 --target claude
```

Commit `apm.yml`, `apm.lock.yaml` and `.claude/`. `apm_modules/` is gitignored
automatically.

**Requires** `gh` authenticated with `repo` scope, `jq`, and Python 3.

## Packages

| Package | Stage | What it does |
|---|---|---|
| `shipyard-contracts` | cross-stage | The verdict schema and comment template both gates read. |
| `verify-runner` | test | The evidence ladder, plus the repo's own suite. Useful standalone. |
| `review-pr-gate` | review | Reviews a PR, gathers evidence, posts one verdict comment. |
| `review-pr-merge` | review | Re-verifies the verdict live, then approves and merges. |
| `maintain-env-sync` | maintain | Fast-forwards the default branch and reinstalls what changed. |
| `bundles/pr-flow` | — | Manifest only; depends on both gates. |

## Using it

```
/review-pr 33            # review, post a verdict comment
/review-pr 33 --dry-run  # render the comment, post nothing
/merge-pr 33             # re-verify the eight gates, approve, merge
/merge-pr 33 --dry-run   # report the gates, change nothing
/sync-env                # match the local checkout and its packages to the default branch
/sync-env --dry-run      # say what it would pull and install
```

Both are also reachable by describing the intent — "have a look at PR 33 and tell me
whether it's safe to merge" — because the skills are model-invoked on their descriptions.
The slash commands are thin entry points into the same procedures.

## The evidence ladder

"The tests passed" is often not evidence. A dependency bump whose test suite mocks the
changed library away is green and proves nothing. So `verify-runner` climbs four rungs:

| Rung | Question |
|---|---|
| 0 · Resolves | Do the dependencies install and stay mutually consistent? |
| 1 · Imports | Does it compile? |
| 2 · Smoke | Does the app boot and serve? |
| 3 · Boundary | Run a probe on base *and* head, and diff. Did behaviour change? |

Rung 3 is the differential test, and it is the only one that can see a silent behaviour
change in a dependency your tests mock out.

A rung that **fails** implicates the change. A rung that **cannot run** — no interpreter, no
key, a port already bound — does not, and yields `NEEDS_HUMAN` rather than a block. Blurring
those two fails good changes and teaches people to ignore the verdict.

## The merge gate

The verdict comment is written by a GitHub account, so anyone with write access could write
one by hand. It is therefore a **cache, never an authority**: every fact it asserts is
re-read live before merging. Eight gates, in
[preconditions.md](packages/review-pr-merge/.apm/skills/review-pr-merge/references/preconditions.md).

Two of them are worth calling out:

- **Gate 4** requires the head SHA to match the reviewed one. Reviewed clean, then pushed,
  then merged on the old review is the failure this exists to prevent.
- **Gate 6 is two-phase.** A PR awaiting its first approval reports `mergeable_state:
  "blocked"` — that means "needs the approval we are about to give", not "unmergeable".
  Checking it *before* approving would abort exactly the PRs the gate exists to land.

A `PreToolUse` hook backstops all of it: a direct `gh pr merge` is blocked unless the gate
wrote a pass marker for that PR at that SHA within the last ten minutes. The marker lives in
`.git/`, so it is per-clone and never committed.

## After the merge: overlay in, real install out

The review gate must never install a pull request's dependency into your environment — the
change is speculative, and if the merge is declined you are left running something that was
never accepted. So `verify-runner` uses a throwaway `PYTHONPATH` overlay.

After the merge that inverts. The default branch pins the new version, and an environment
still holding the old one is not cautious, it is wrong — every later test run and review
happens against something the repository no longer describes.

So `review-pr-merge` calls `maintain-env-sync` once a merge lands (unless
`post_merge.sync_local: false`). It fast-forwards, installs **only what the manifest diff
changed**, then asserts the interpreter actually imports the pinned version — `pip show`
reports metadata, but the import is what your application will really get.

It refuses rather than surprises: no pulling over uncommitted tracked changes, no switching
you off a feature branch, no merge commit invented to make a sync succeed.

## Configuration

Optional `.shipyard.yml` in the consuming repository:

```yaml
auto_merge: true
merge_method: squash
delete_branch: true
trusted_bots: ["dependabot[bot]", "renovate[bot]"]

runtime:                          # a bare worktree has no venv, .env or gitignored data
  python: ./venv/bin/python
  env_file: .env
  link: [embeddings.index]

test_command: pytest -q
import_check: [utils.pdf_processor, web.app]
smoke:
  boot: python web/app.py
  health_url: http://127.0.0.1:5001/
  expect_status: 200
  timeout_s: 60
boundary_probe: |
  from utils.pdf_processor import extract_text_from_pdf
  print(extract_text_from_pdf("data/vm1kkye15yy2.pdf")[:5000])

dependency_policy:
  auto_merge_update_types: [patch, minor]   # major and unknown never auto-merge
  behaviour_diff: warn                      # warn | block

post_merge:
  sync_local: true                          # run maintain-env-sync after a merge
  pull: ff-only
  install: ./venv/bin/python -m pip install -r requirements.txt
```

Without it, stacks are detected and the result says so, so a wrong guess looks like a guess.

## Safety

- **Untrusted authors never get executed.** Climbing a rung runs the PR's code with the
  repository's real credentials. For a fork PR that is credential exfiltration, so the gate
  runs nothing and returns `NEEDS_HUMAN`.
- **PR content is data, not instructions.** Titles, bodies, diffs, upstream release notes
  and comments are quoted into the verdict, never followed. Text in a PR that tries to
  direct the reviewer is quoted verbatim and forces `NEEDS_HUMAN`.
- **Major bumps never auto-merge.**
- **The user's working tree is never touched.** Everything runs in a scratchpad worktree,
  removed afterwards.

## Credits

Diff judgement delegates to [`mattpocock/skills`](https://github.com/mattpocock/skills)
`code-review` (MIT), pinned at `v1.2.3` — a two-axis standards/spec review that fans out to
parallel subagents.

## Maintenance

```bash
apm outdated   # what has drifted upstream
apm update     # refresh refs, rewrite the lockfile
apm audit      # rehash deployed files -- catches a hand-edit that softened a gate
```

## Licence

MIT.
