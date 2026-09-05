#!/usr/bin/env bash
# Block `gh pr merge` unless the shipyard merge gate cleared this exact PR at this exact
# head SHA within the last 10 minutes.
#
# Runs as a PreToolUse hook on EVERY Bash call, so the non-merge path must be as close to
# free as possible: one substring test, then exit 0.
#
# Exit 0 = allow. Exit 2 = block, with the reason on stderr for the model to read.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
payload=$(cat)

# Fast path. The overwhelming majority of Bash calls are nothing to do with merging.
case "$payload" in
  *"gh pr merge"*) ;;
  *) exit 0 ;;
esac

decision=$(printf '%s' "$payload" | python3 "${HERE}/parse-merge-command.py" 2>/dev/null || echo "MERGE")

case "$decision" in
  ALLOW) exit 0 ;;
esac

pr="${decision#MERGE}"
pr="${pr# }"

if [ -z "$pr" ]; then
  echo "shipyard merge-guard: BLOCKED. 'gh pr merge' without an explicit PR number." >&2
  echo "Run /merge-pr <number> so the eight preconditions are checked first." >&2
  exit 2
fi

git_dir=$(git rev-parse --git-dir 2>/dev/null || echo "")
if [ -z "$git_dir" ]; then
  echo "shipyard merge-guard: BLOCKED. Not inside a git repository, so no merge-gate pass can be verified." >&2
  exit 2
fi

repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "")
head_sha=$(gh api "repos/${repo}/pulls/${pr}" --jq .head.sha 2>/dev/null || echo "")
if [ -z "$head_sha" ]; then
  echo "shipyard merge-guard: BLOCKED. Could not read PR #${pr}'s head SHA to verify a gate pass." >&2
  exit 2
fi

marker="${git_dir}/shipyard/${pr}-${head_sha}.pass"
if [ ! -f "$marker" ]; then
  echo "shipyard merge-guard: BLOCKED. No merge-gate pass for PR #${pr} at ${head_sha:0:8}." >&2
  echo "Run /merge-pr ${pr} instead -- it re-verifies the verdict against live GitHub state," >&2
  echo "then approves and merges. Do not work around this by merging another way." >&2
  exit 2
fi

written=$(cat "$marker" 2>/dev/null || echo 0)
age=$(( $(date -u +%s) - written ))
if [ "$age" -gt 600 ]; then
  echo "shipyard merge-guard: BLOCKED. The pass for PR #${pr} is ${age}s old (max 600)." >&2
  echo "Re-run /merge-pr ${pr} so the preconditions are checked against current state." >&2
  exit 2
fi

exit 0
