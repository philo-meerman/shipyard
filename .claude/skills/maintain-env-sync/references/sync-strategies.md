# Sync strategies per stack

## Which files are manifests

Diff these between the old and new HEAD to decide whether anything needs installing:

| Stack | Manifests |
|---|---|
| Python (pip) | `requirements*.txt`, `constraints*.txt` |
| Python (uv/poetry/pipenv) | `pyproject.toml`, `uv.lock`, `poetry.lock`, `Pipfile.lock` |
| Node | `package.json`, `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock` |
| Go | `go.mod`, `go.sum` |
| Rust | `Cargo.toml`, `Cargo.lock` |
| Ruby | `Gemfile`, `Gemfile.lock` |

```bash
git diff --name-only "$OLD_HEAD" "$NEW_HEAD" -- requirements.txt pyproject.toml
```

Empty output means stop. Nothing to do is the common case and should cost nothing.

## Install commands

Prefer `post_merge.install` from `.shipyard.yml`. Otherwise:

| Stack | Command |
|---|---|
| pip | `<py> -m pip install -r requirements.txt` |
| uv | `uv sync` |
| poetry | `poetry install` |
| pipenv | `pipenv sync` |
| npm | `npm ci` |
| pnpm / yarn | `pnpm i --frozen-lockfile` / `yarn --immutable` |
| Go | `go mod download` |
| Rust | `cargo fetch --locked` |
| Ruby | `bundle install` |

Always use the project's own interpreter (`runtime.python`, typically `./venv/bin/python`),
never a bare `python3`. Installing into the wrong environment is the failure this whole
skill is meant to prevent, so it would be a poor way to fail.

## Verifying a pip sync

Read the pinned version out of the manifest, then compare against what the interpreter
actually imports:

```bash
pinned=$(sed -n 's/^pypdf==//p' requirements.txt)
actual=$(<py> -c "import pypdf; print(pypdf.__version__)")
[ "$pinned" = "$actual" ] || echo "MISMATCH: pinned ${pinned}, importable ${actual}"
```

`pip show` is weaker than an import: it reports metadata, while the import is what the
application will actually get. When they disagree, something is shadowing the venv and the
user needs to know.

Finish with `<py> -m pip check` so a satisfied pin that broke a sibling does not pass
unnoticed.

## What never to do

- Never `pip install --upgrade <pkg>` beyond what the manifest pins. The manifest is the
  contract; sync converges on it, it does not go exploring.
- Never delete and rebuild an environment to force a sync. That discards editable installs,
  local wheels and anything hand-placed, and takes minutes instead of seconds.
- Never `git pull` without `--ff-only`. A sync that silently creates a merge commit has
  changed the user's history to serve its own convenience.
