# Review lanes

Two lanes. Pick by looking at which files the diff touches.

## `dependency-bump`

**Selected when** every changed file is a dependency manifest or lockfile:
`requirements*.txt`, `pyproject.toml`, `poetry.lock`, `uv.lock`, `Pipfile*`,
`package.json`, `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `go.mod`, `go.sum`,
`Cargo.toml`, `Cargo.lock`, `Gemfile*`, `.github/workflows/*` pinning an action version.

If even one source file changed, it is a `code-change`. A bump that also edits code is
someone doing a migration, and it deserves the full review.

### What this lane does

1. **Parse the release notes from the PR body.** Dependabot embeds the upstream changelog
   between the two versions directly in the PR description. There is no changelog to
   fetch — read what is already there. Extract entries mentioning breaking changes, removed
   or renamed APIs, behavioural fixes, and security fixes.
2. **Read the compatibility score.** The body carries a
   `dependabot-badges.githubapp.com/badges/compatibility_score` image URL. Its query string
   holds `dependency-name`, `previous-version` and `new-version` — a free, authoritative
   parse of what actually changed, better than inferring from the title.
3. **Derive `update_type`** by comparing the versions as semver: `major`, `minor`, `patch`,
   or `unknown` when they do not parse. This drives the merge gate's policy check; majors
   never auto-merge.
4. **Locate the import sites.** Grep the source tree for the package's import name (which
   is not always the distribution name — `pypdf` imports as `pypdf`, but `scikit-learn`
   imports as `sklearn`, `Pillow` as `PIL`). Record file and line. These sites are what the
   evidence ladder's rung 1 imports and what rung 3 probes.
5. **Run the full ladder** — 0, 1, 2, 3 — plus the unit suite with a relevance judgement.
6. **Skip the diff review.** A one-line version change gives a code reviewer nothing. The
   risk lives in the upstream changelog and in whether the app still works, both of which
   are covered above.

### Cross-reference

The valuable output of this lane is the join: *do any of the behavioural changes named in
the release notes touch the import sites found in step 4?* Say so explicitly in the
comment. "Six releases of text-extraction fixes, and this repo calls
`extract_text_from_pdf`" is the sentence a human needs; "tests passed" is not.

## `code-change`

**Selected for** everything else.

1. Delegate diff judgement to the `pr-risk-reviewer` subagent, which drives the upstream
   `code-review` skill (standards axis and spec axis, each in its own thread).
2. Supply the spec source directly: the PR body, plus any linked issue fetched with
   `gh issue view`. The upstream skill looks for `docs/agents/issue-tracker.md` from its own
   setup flow; we do not require that file in every repository, so pass the spec inline and
   tell the subagent to skip the spec axis when neither a body nor a linked issue offers
   one.
3. Run rungs 1 and 2 plus the unit suite. Add rung 0 only if a manifest also changed. Rung 3
   needs a named boundary, so run it only when the change is confined to one module with a
   configured `boundary_probe`.

## Neither lane

A diff touching only `*.md`, `LICENSE`, or comments needs no ladder. Say that plainly, run
nothing, and let the verdict rest on the diff review alone. Spending two minutes booting an
app to verify a typo fix trains people to stop reading the verdict.
