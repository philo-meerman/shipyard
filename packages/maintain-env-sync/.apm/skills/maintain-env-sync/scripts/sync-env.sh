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

# --- Resolve the interpreter early: the drift check needs it -------------------------
py="${PY_CFG:-}"
if [ -z "$py" ]; then
  for c in ./venv/bin/python ./.venv/bin/python ./env/bin/python; do
    [ -x "$c" ] && { py="$c"; break; }
  done
fi

# --- Does the environment actually match the manifest? -------------------------------
# A pull that changed a manifest is one reason to install. It is not the only one: a
# previous sync may have failed, or someone may have installed by hand. What matters is
# whether the environment matches what the branch pins, so check that directly --
# otherwise a failed sync reports "nothing to do" on the retry and the drift goes quiet.
drift='[]'
if [ -n "$py" ] && [ -f requirements.txt ]; then
  drift=$($py - <<'PYD' 2>/dev/null || echo '[]'
import json, re, pathlib
from importlib import metadata

def same(a, b):
    """Compare versions by value, not by spelling: 1.81 and 1.81.0 are one version."""
    if a is None or b is None:
        return False
    try:
        from packaging.version import Version
        return Version(a) == Version(b)
    except Exception:  # pylint: disable=broad-exception-caught
        norm = lambda v: tuple(
            int(x) if x.isdigit() else x
            for x in re.split(r"[._-]", v)
        )
        pa, pb = list(norm(a)), list(norm(b))
        while len(pa) < len(pb):
            pa.append(0)
        while len(pb) < len(pa):
            pb.append(0)
        return pa == pb

rows = []
for line in pathlib.Path("requirements.txt").read_text().splitlines():
    m = re.match(r"^\s*([A-Za-z0-9_.\-]+)\s*==\s*([^\s#;]+)", line)
    if not m:
        continue
    name, pinned = m.group(1), m.group(2)
    try:
        actual = metadata.version(name)
    except Exception:  # not installed at all
        actual = None
    if not same(actual, pinned):
        rows.append({"package": name, "pinned": pinned, "installed": actual})
print(json.dumps(rows))
PYD
)
fi
n_drift=$(jq 'length' <<<"$drift" 2>/dev/null || echo 0)

if [ -z "${changed// /}" ] && [ "$n_drift" -eq 0 ]; then
  jq -n --arg ob "${old_head:0:8}" --arg nb "${new_head:0:8}" --argjson n "$commits_pulled" \
    '{synced: true, commits_pulled: $n, from: $ob, to: $nb, manifests_changed: [], installed: false, drift: [], note: "already in sync with the default branch"}'
  exit 0
fi

if [ -z "${changed// /}" ]; then
  changed="requirements.txt"
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
        --arg ch "${changed% }" --arg ic "$install_cmd" --argjson dr "$drift" \
    '{dry_run: true, would_pull: $n, from: $ob, to: $nb, manifests_changed: ($ch|split(" ")), drift: $dr, would_run: $ic}'
  exit 0
fi

install_log=$(mktemp)
if ! eval "$install_cmd" >"$install_log" 2>&1; then
  # Diagnose before dumping. "No matching distribution" against an interpreter this old
  # almost always means the manifest pins a version that dropped support for it -- a
  # different problem from a broken install, and one the user must decide how to fix.
  unsat=$(grep -o 'No matching distribution found for [^ ]*' "$install_log" | head -1 | sed 's/.*for //')
  if [ -n "$unsat" ]; then
    pyver=$([ -n "$py" ] && $py -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo "unknown")
    pkg="${unsat%%==*}"
    echo "sync-env: FAILED -- the default branch pins ${unsat}, which has no distribution installable on Python ${pyver}." >&2
    echo "The branch was still fast-forwarded; the environment is unchanged." >&2
    echo "This is a manifest/interpreter mismatch, not a broken install. Either the venv needs a newer Python, or ${pkg} needs pinning back to a version that supports ${pyver}." >&2
    rm -f "$install_log"
    jq -n --arg ob "${old_head:0:8}" --arg nb "${new_head:0:8}" --argjson n "$commits_pulled" \
          --arg u "$unsat" --arg pv "$pyver" \
      '{synced: true, commits_pulled: $n, from: $ob, to: $nb, installed: false,
        failure: "unsatisfiable-requirement", requirement: $u, interpreter_python: $pv,
        environment_changed: false, passed: false}'
    exit 1
  fi
  echo "sync-env: install failed" >&2; tail -20 "$install_log" >&2; rm -f "$install_log"; exit 1
fi
rm -f "$install_log"

# --- Verify: what the interpreter actually imports, not what pip claims ---------------
verify='[]'
if [ -n "$py" ] && [ -f requirements.txt ]; then
  verify=$($py - <<'PYV' 2>/dev/null || echo '[]'
import json, re, pathlib
from importlib import metadata

def same(a, b):
    """Compare versions by value, not by spelling: 1.81 and 1.81.0 are one version."""
    if a is None or b is None:
        return False
    try:
        from packaging.version import Version
        return Version(a) == Version(b)
    except Exception:  # pylint: disable=broad-exception-caught
        norm = lambda v: tuple(
            int(x) if x.isdigit() else x
            for x in re.split(r"[._-]", v)
        )
        pa, pb = list(norm(a)), list(norm(b))
        while len(pa) < len(pb):
            pa.append(0)
        while len(pb) < len(pa):
            pb.append(0)
        return pa == pb

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
                 "match": same(actual, pinned)})
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
