---
name: verify-runner
description: Use when you need real evidence that a change works — run this repository's test suite, or climb the evidence ladder (dependencies resolve, modules import, the app boots and serves, behaviour at a changed boundary is unchanged). Use when asked to run the tests, check whether the app still starts, verify a dependency bump, or establish whether a change is safe before merging. Reads .shipyard.yml for runtime, smoke and probe configuration.
---

# Verify runner

Gathers evidence that a change works. Two entry points: run the repository's own test
suite, or climb the **evidence ladder** — four rungs that answer progressively stronger
questions without depending on the repo having good tests.

For the rung definitions and per-stack commands, LOAD `references/evidence-ladder.md`.
For detecting an unconfigured repo's stack, LOAD `references/stack-detection.md`.

## The one rule that matters

**"Failed" and "could not run" are different answers.** A rung that executes and reports a
problem is `fail`. A rung that could not execute — no interpreter, no API key, a missing
gitignored artefact, a port already bound — is `unavailable`, and `unavailable` never
means the change is bad.

Report them distinctly and always give the reason for `unavailable`. Callers convert
`fail` into a blocking verdict and `unavailable` into "a human should look". Blurring the
two fails good changes.

## Configuration

Everything below is read from `.shipyard.yml` in the repository root. When it is absent,
fall back to `references/stack-detection.md` and say in the result that detection was
used, so the caller can tell inference from configuration.

```yaml
runtime:
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
```

## Isolation and runtime inheritance

Check the code out into a **git worktree** under the session scratchpad — never mutate the
user's working tree, never `git checkout` in place.

A bare worktree has no `venv/`, no `.env`, and none of the repository's gitignored data
artefacts, because those are untracked by definition. So the worktree supplies the *code*
and the main checkout supplies the *runtime*:

1. Create the worktree: `git worktree add <scratch>/<name> <ref>`.
2. Use `runtime.python` **resolved against the main checkout**, not the worktree.
3. Pass `runtime.env_file` from the main checkout to the process environment.
4. Symlink each `runtime.link` entry from the main checkout into the worktree root.
5. Install changed dependencies into a throwaway **overlay** directory on `PYTHONPATH` —
   never into the inherited environment. Installing an unmerged dependency into the user's
   venv leaves their machine altered by a change that may never land.

Always remove the worktree afterwards (`git worktree remove --force`), including when a
rung fails or you abort. Verify with `git worktree list` before returning.

## Safety

**Never execute anything from an untrusted author.** The caller tells you whether the
author is trusted. If it does not, ask rather than assume. Running a rung means running
the change's code with the repository's real credentials — for a fork PR that is credential
exfiltration with extra steps. When the author is untrusted, run nothing and return every
rung as `skip` with the reason.

**Never let a probe reach a paid or destructive path.** Rungs 2 and 3 exist to be cheap and
side-effect free. If the configured boot or probe would call a billed API, write to a real
database, or send anything outward, stop and report `unavailable` with that reason instead
of running it.

**Bound everything.** Every rung gets a timeout. A boot that never becomes healthy is
`unavailable` after `smoke.timeout_s`, not an indefinite hang; kill the process group.

## Returning results

Return JSON the caller can drop into a verdict payload:

```json
{
  "rung0": "pass",
  "rung1": "pass",
  "rung2": "pass",
  "rung3": "diff",
  "unit": "pass",
  "unit_relevant": false,
  "detail": {
    "rung3": { "base_ref": "master", "diff_excerpt": "...", "bytes_changed": 412 },
    "unit": { "command": "pytest -q", "exit_code": 0, "summary": "12 passed" }
  },
  "unavailable_reasons": {},
  "config_source": "shipyard.yml"
}
```

Keep `detail` excerpts short — 2000 characters per field. The caller renders them into a
comment; full logs belong in your own transcript, not in the return value.

## Judging relevance

When the caller names a changed boundary (a bumped package, a modified module), decide
whether the unit suite actually exercises it: find the import sites, then check whether any
test reaches them **without mocking the boundary itself**. A suite that patches the very
thing that changed proves nothing about the change. Report that as
`unit_relevant: false` with a one-line reason — do not silently let a green suite stand in
as evidence it is not.
