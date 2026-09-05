# Stack detection

Used only when `.shipyard.yml` does not configure a command. Always report
`config_source: "detected"` so the caller can distinguish inference from configuration —
a wrong guess should look like a guess.

## Interpreter and package manager

Prefer, in order:

1. `runtime.python` from `.shipyard.yml`.
2. A virtualenv in the repo: `venv/bin/python`, `.venv/bin/python`, `env/bin/python`.
3. `uv` / `poetry` / `pipenv` if their lockfile is present at the root.
4. `python3` on PATH — **last resort**, and note it: a bare interpreter almost certainly
   lacks the project's dependencies, so rung 0 must run before anything else.

## Test command

| Signal | Command |
|---|---|
| `pytest.ini`, `pyproject.toml` with `[tool.pytest]`, `setup.cfg` with `[tool:pytest]` | `pytest -q` |
| A `tests/` directory of `test_*.py` and no pytest config | `pytest -q` (pytest runs unittest classes) |
| `package.json` with `scripts.test` | `npm test --silent` |
| `go.mod` | `go test ./...` |
| `Cargo.toml` | `cargo test --locked` |
| `Makefile` with a `test:` target | `make test` |
| `.pre-commit-config.yaml` and nothing else | `pre-commit run --all-files` — lint, not tests; say so |

When several match, prefer the most specific and report which signal you used. When none
match, return `unit: "unavailable"` with "no test command detected" — do **not** invent one.

## Boot command for rung 2

| Signal | Boot |
|---|---|
| `app.run(...)` in a Flask module | run that module directly |
| `if __name__ == "__main__"` in an obvious entrypoint (`app.py`, `main.py`, `run.py`) | run it |
| `package.json` with `scripts.start` | `npm start` |
| `Dockerfile` with a `CMD` | note it, but prefer the native command — Docker turns a 10-second rung into a minutes-long one |

Read the source for the bound port rather than assuming 8000 or 3000; a Flask app calling
`app.run(port=5001)` serves on 5001 and nothing else. If the port is already in use, that
is `unavailable`, not `fail` — something else on the machine is holding it.

If no entrypoint is identifiable, `rung2: "unavailable"` with "no boot command detected".
That is a fine outcome; it tells the caller the repo needs a `smoke:` block.

## Import targets for rung 1

Grep the source tree for the changed package name to find direct import sites, then find
the first-party modules importing those. Exclude `venv/`, `node_modules/`, `apm_modules/`,
`.git/`, and any worktrees. Cap the list at ~10 modules; importing every module in a large
repo is slow and rarely adds signal beyond the first few.
