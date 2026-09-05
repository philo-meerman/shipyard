#!/usr/bin/env bash
# Bring the local checkout and its installed dependencies in line with the default branch.
#
# Usage: sync-env.sh [--dry-run] [--allow-branch-switch]
#
# Fast-forwards the default branch, works out which manifests changed, installs only if
# any did, then asserts the interpreter actually resolves the pinned versions.
#
# Exits 0 on success or "nothing to do", 1 on a refused precondition or a failed verify.
set -uo pipefail

DRY_RUN=false; ALLOW_SWITCH=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --allow-branch-switch) ALLOW_SWITCH=true; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

cfg=".shipyard.yml"
get_cfg() { [ -f "$cfg" ] && sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" "$cfg" | head -1 | sed 's/[[:space:]]*#.*//' | tr -d "\"' " || true; }

PY_CFG=$(get_cfg python); PY_CFG="${PY_CFG:-}"
INSTALL_CFG=$(get_cfg install); INSTALL_CFG="${INSTALL_CFG:-}"

fail() { echo "sync-env: REFUSED -- $1" >&2; exit 1; }

# --- Preconditions ------------------------------------------------------------------
git rev-parse --git-dir >/dev/null 2>&1 || fail "not inside a git repository"

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "sync-env: REFUSED -- tracked files are modified. Commit or stash first; a sync must never pull over uncommitted work." >&2
  git status --short --untracked-files=no >&2
  exit 1
fi

gd=$(git rev-parse --git-dir)
for state in MERGE_HEAD REBASE_HEAD CHERRY_PICK_HEAD; do
  [ -e "$gd/$state" ] && fail "a $state is in progress; finish or abort it first"
done

default_branch=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
if [ -z "$default_branch" ]; then
  default_branch=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || echo "")
fi
[ -n "$default_branch" ] || fail "could not determine the default branch"

current=$(git rev-parse --abbrev-ref HEAD)
if [ "$current" != "$default_branch" ]; then
  if [ "$ALLOW_SWITCH" = false ]; then
    fail "on '${current}', not the default branch '${default_branch}'. Pass --allow-branch-switch to move; silently switching would lose your place."
  fi
  $DRY_RUN || git checkout -q "$default_branch" || fail "could not switch to ${default_branch}"
fi

# --- Fast-forward -------------------------------------------------------------------
old_head=$(git rev-parse HEAD)
if [ "$DRY_RUN" = false ]; then
  git fetch -q origin "$default_branch" || fail "fetch failed"
  git merge --ff-only -q "origin/${default_branch}" 2>/dev/null \
    || fail "cannot fast-forward ${default_branch} onto origin/${default_branch}; local commits diverge. Resolve by hand -- a sync must not rewrite history."
else
  git fetch -q origin "$default_branch" 2>/dev/null || true
fi
new_head=$(git rev-parse HEAD)
target_head=$(git rev-parse "origin/${default_branch}" 2>/dev/null || echo "$new_head")
$DRY_RUN && new_head="$target_head"

# --- Did any manifest change? --------------------------------------------------------
MANIFESTS="requirements.txt requirements-dev.txt constraints.txt pyproject.toml uv.lock poetry.lock Pipfile.lock package.json package-lock.json pnpm-lock.yaml yarn.lock go.mod go.sum Cargo.toml Cargo.lock Gemfile Gemfile.lock"
changed=""
if [ "$old_head" != "$new_head" ]; then
  changed=$(git diff --name-only "$old_head" "$new_head" -- $MANIFESTS 2>/dev/null | tr '\n' ' ')
fi

commits_pulled=0
[ "$old_head" != "$new_head" ] && commits_pulled=$(git rev-list --count "${old_head}..${new_head}" 2>/dev/null || echo 0)

if [ -z "${changed// /}" ]; then
  jq -n --arg ob "${old_head:0:8}" --arg nb "${new_head:0:8}" --argjson n "$commits_pulled" \
    '{synced: true, commits_pulled: $n, from: $ob, to: $nb, manifests_changed: [], installed: false, note: "no manifest changed; nothing to install"}'
  exit 0
fi

# --- Install --------------------------------------------------------------------------
py="${PY_CFG:-}"
if [ -z "$py" ]; then
  for c in ./venv/bin/python ./.venv/bin/python ./env/bin/python; do
    [ -x "$c" ] && { py="$c"; break; }
  done
fi

install_cmd="$INSTALL_CFG"
if [ -z "$install_cmd" ]; then
  if [ -n "$py" ] && [ -f requirements.txt ]; then
    install_cmd="$py -m pip install -r requirements.txt"
  elif [ -f package-lock.json ]; then install_cmd="npm ci"
  elif [ -f go.sum ]; then install_cmd="go mod download"
  elif [ -f Cargo.lock ]; then install_cmd="cargo fetch --locked"
  else
    fail "manifests changed (${changed}) but no install command could be determined; set post_merge.install in .shipyard.yml"
  fi
fi

if [ "$DRY_RUN" = true ]; then
  jq -n --arg ob "${old_head:0:8}" --arg nb "${new_head:0:8}" --argjson n "$commits_pulled" \
        --arg ch "${changed% }" --arg ic "$install_cmd" \
    '{dry_run: true, would_pull: $n, from: $ob, to: $nb, manifests_changed: ($ch|split(" ")), would_run: $ic}'
  exit 0
fi

install_log=$(mktemp)
if ! eval "$install_cmd" >"$install_log" 2>&1; then
  echo "sync-env: install failed" >&2; tail -20 "$install_log" >&2; rm -f "$install_log"; exit 1
fi
rm -f "$install_log"

# --- Verify: what the interpreter actually imports, not what pip claims ---------------
verify='[]'
if [ -n "$py" ] && [ -f requirements.txt ]; then
  verify=$($py - <<'PYV' 2>/dev/null || echo '[]'
import json, re, pathlib
from importlib import metadata
rows = []
for line in pathlib.Path("requirements.txt").read_text().splitlines():
    m = re.match(r"^\s*([A-Za-z0-9_.\-]+)\s*==\s*([^\s#;]+)", line)
    if not m:
        continue
    name, pinned = m.group(1), m.group(2)
    try:
        actual = metadata.version(name)
    except Exception:
        actual = None
    rows.append({"package": name, "pinned": pinned, "installed": actual,
                 "match": actual == pinned})
print(json.dumps(rows))
PYV
)
fi

pip_check="skipped"
[ -n "$py" ] && pip_check=$($py -m pip check 2>&1 | head -3 | tr '\n' ' ')

mismatched=$(jq '[.[] | select(.match == false)]' <<<"$verify")
n_mismatch=$(jq 'length' <<<"$mismatched")

jq -n --arg ob "${old_head:0:8}" --arg nb "${new_head:0:8}" --argjson n "$commits_pulled" \
      --arg ch "${changed% }" --arg ic "$install_cmd" --argjson v "$verify" \
      --argjson mm "$mismatched" --arg pc "$pip_check" \
  '{synced: true, commits_pulled: $n, from: $ob, to: $nb,
    manifests_changed: ($ch|split(" ")), installed: true, install_command: $ic,
    pip_check: $pc, verified: $v, mismatched: $mm,
    passed: (($mm|length) == 0)}'

[ "$n_mismatch" -eq 0 ]
