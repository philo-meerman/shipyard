# The evidence ladder

Four rungs plus the repository's own suite. Each answers a stronger question than the last.
Run them in order and stop climbing when a rung `fail`s — a repo whose dependencies do not
resolve cannot tell you anything useful about whether its app boots.

Each rung returns `pass` | `fail` | `skip` | `unavailable`. Rung 3 may also return `diff`.

---

## Rung 0 — Resolves

*Do the declared dependencies install, and are they mutually consistent?*

| Stack | Command |
|---|---|
| Python | `<py> -m pip install -r requirements.txt` then `<py> -m pip check` |
| Python (uv) | `uv sync --frozen` |
| Python (poetry) | `poetry check --lock` then `poetry install` |
| Node | `npm ci` (or `pnpm i --frozen-lockfile`, `yarn --immutable`) |
| Go | `go mod verify` then `go mod tidy -diff` |
| Rust | `cargo fetch --locked` |

`pip check` matters more than the install: it catches the case where the new version
satisfies its own pin but conflicts with a sibling. That is the most common way a
dependency bump breaks a project, and installs alone do not surface it.

`fail` when the install errors or `pip check` reports a conflict. `unavailable` when there
is no usable interpreter or package manager.

### Never install into the user's environment

The runtime is *inherited*, which means the interpreter you are handed is the one the user
develops against. Installing the PR's requirements into it would leave their machine
running an unmerged dependency — and if the merge is later declined, silently so.

Install into an **overlay** instead, and put it ahead of the inherited environment:

```bash
pip install --target "$OVERLAY" --upgrade <package>==<new-version>
PYTHONPATH="$OVERLAY:${PYTHONPATH:-}" <py> -c 'import <mod>; print(<mod>.__version__)'
```

For a dependency bump, install **only the changed packages** at their new versions. The
rest of the environment is already correct in the inherited venv, and reinstalling it
turns a ten-second rung into a multi-minute one for no signal.

Always assert the overlay actually won: import the package and print its version before
trusting rungs 1–3. A shadowing failure makes every later rung a test of the *old* version
while reporting on the new one, which is worse than not running them.

Delete the overlay afterwards. Verify the inherited environment is untouched — for pip,
`<py> -m pip show <package>` should still report the *old* version when you are done.

## Rung 1 — Imports

*Does it compile?*

| Stack | Command |
|---|---|
| Python | `<py> -c "import <mod>"` for each module in `import_check` |
| TypeScript | `npx tsc --noEmit` |
| Go | `go build ./...` |
| Rust | `cargo check --locked` |

For Python, prefer the explicit `import_check` list over guessing. Without it, import every
first-party module that transitively imports the changed package — find them with a grep
for the package name across the source tree, then walk up to the modules that import
*those*.

Import a module, do not run it. A module whose import has side effects (starting a server,
loading a multi-gigabyte index, calling an API) will make this rung slow or expensive; when
you detect that, report `unavailable` with the reason rather than paying the cost — rung 2
covers boot behaviour properly.

## Rung 2 — Smoke

*Does the application boot and serve?*

1. Start `smoke.boot` as a background process group, with the inherited environment.
2. Poll `smoke.health_url` every 500ms until it returns `smoke.expect_status`, or
   `smoke.timeout_s` elapses.
3. Assert the body is non-empty and, for an HTML endpoint, that it looks like a document.
4. Kill the whole process group. Confirm the port is released.

`pass` when the expected status arrives in time. `fail` when the process exits non-zero, or
it serves but returns the wrong status. `unavailable` when the port is already bound, the
boot command is missing, or the timeout elapses with no response at all — a hang is not
evidence of a bad change.

Capture the boot process's stderr regardless of outcome; a traceback on startup is the most
useful thing this rung produces.

**Never let the smoke path make a billed API call.** If booting the app eagerly builds an
index, embeds a corpus, or calls a model, that is a configuration problem — report
`unavailable` with the reason. Rung 2 must stay cheap enough to run on every review.

## Rung 3 — Boundary

*Did behaviour change at the boundary this change touches?*

This is a **differential** rung: the same probe, run twice, against two versions.

1. Run `boundary_probe` with the overlay active — the new version.
2. Run the same probe with the overlay removed — the inherited environment still holds the
   base version, so no second install is needed.
3. Diff the two outputs.

Running base second, from the untouched environment, is also the cheapest available proof
that the overlay was real: if the two runs are byte-identical *and* the version assertion
showed different versions, the probe does not reach the changed code and rung 3 is `skip`,
not `pass`.

- Identical → `pass`.
- Differ → `diff`. Report a unified-diff excerpt and the byte delta. **This is not a
  failure.** For a bug-fix release, changed output is frequently the point. Whether it
  blocks is the caller's policy decision.
- Probe raises on head but not base → `fail`. That is a real regression.
- No probe configured, or it cannot run → `skip` / `unavailable`.

A good probe is deterministic, offline, and reads a tracked input file. A probe that hits
the network or an LLM is not a probe; it is a flake generator.

## Unit — the repository's own suite

Run `test_command`, or the detected equivalent. Report exit code and a short summary.

### Always baseline against the merge base

A red suite does not mean this change broke it. Repositories carry pre-existing failures —
a stale assertion, a test nobody has run in a year — and blocking a good pull request over
one of them is how a gate loses the user's trust in a single afternoon.

So run the suite **twice**: once at the head, once at the merge base, and compare the sets
of failing test IDs.

| Base | Head | Result |
|---|---|---|
| passes | passes | `pass` |
| fails | fails (same IDs) | `pass`, with `pre_existing_failures` listed |
| passes | fails | `fail` — this change broke them; name the new IDs |
| fails | passes | `pass`, and note the change fixed something |

Only a **newly** failing test is a `fail`. Report pre-existing failures in the detail so
they are visible without being blocking — they are a real problem, just not this pull
request's problem.

Skip the baseline run only when the head run is fully green; there is nothing to explain.

Then judge **relevance** separately: does this suite exercise the changed boundary without
mocking it? Read the tests that touch the affected modules and look for `patch`, `mock`,
`stub`, `monkeypatch` or a fake aimed at the boundary itself. A suite that mocks
`PdfReader` cannot tell you anything about a pypdf upgrade, however green it is.

Report `unit_relevant: false` with a one-line reason whenever the coverage is absent or
mocked away. Never present a green-but-irrelevant suite as evidence for the change.

---

## Choosing which rungs to run

| Situation | Rungs |
|---|---|
| Dependency bump | 0, 1, 2, 3, unit |
| Code change touching app code | 1, 2, unit (0 only if a manifest changed) |
| Docs / comments only | none — say so |
| Untrusted author | none — `skip` all, with the reason |
