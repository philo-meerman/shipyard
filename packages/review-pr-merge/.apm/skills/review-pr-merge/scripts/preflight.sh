#!/usr/bin/env bash
# Evaluate the eight shipyard merge preconditions against LIVE GitHub state.
#
# Usage: preflight.sh <pr-number> [--phase pre|post] [owner/repo]
#
#   --phase pre   (default) gate 6 accepts mergeable_state "blocked" -- a PR awaiting its
#                 first approving review is blocked until we approve it.
#   --phase post  gate 6 requires "clean"/"has_hooks". Run after approving, before merging.
#
# Prints a JSON report. Exits 0 when every gate passes, 1 otherwise.
# On a clean sweep in phase "post", writes .git/shipyard/<pr>-<sha>.pass, which the
# merge-guard hook requires before it will allow `gh pr merge`.
set -euo pipefail

PR=""; PHASE="pre"; REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --phase) PHASE="$2"; shift 2 ;;
    *) if [ -z "$PR" ]; then PR="$1"; else REPO="$1"; fi; shift ;;
  esac
done
[ -n "$PR" ] || { echo "usage: preflight.sh <pr-number> [--phase pre|post] [owner/repo]" >&2; exit 2; }
REPO="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"

me=$(gh api user --jq .login)
pr=$(gh api "repos/${REPO}/pulls/${PR}")
head_sha=$(jq -r .head.sha <<<"$pr")
author=$(jq -r .user.login <<<"$pr")
draft=$(jq -r .draft <<<"$pr")
mergeable=$(jq -r .mergeable <<<"$pr")
mstate=$(jq -r .mergeable_state <<<"$pr")

comments=$(gh api --paginate "repos/${REPO}/issues/${PR}/comments" \
  --jq '[.[] | select(.body | contains("shipyard:verdict")) | {id, author: .user.login, body}]' | jq -s 'add // []')
n_verdicts=$(jq 'length' <<<"$comments")

fails=()
add_fail() { fails+=("$1"); }

# --- Gate 1: exactly one parseable verdict -----------------------------------------
payload='null'
if [ "$n_verdicts" -eq 0 ]; then
  add_fail "gate1: no shipyard:verdict comment found -- run /review-pr ${PR} first"
elif [ "$n_verdicts" -gt 1 ]; then
  add_fail "gate1: ${n_verdicts} verdict comments found, expected exactly 1 -- contract violation, resolve by hand"
else
  body=$(jq -r '.[0].body' <<<"$comments")
  payload=$(printf '%s' "$body" | sed -n '/shipyard:verdict/,/-->/p' | sed '1d;$d' | jq -c . 2>/dev/null || echo 'null')
  if [ "$payload" = "null" ]; then
    add_fail "gate1: verdict block is not parseable JSON"
  elif [ "$(jq -r '.schema // ""' <<<"$payload")" != "shipyard/verdict/v1" ]; then
    add_fail "gate1: unexpected schema '$(jq -r '.schema // "missing"' <<<"$payload")', expected shipyard/verdict/v1"
  fi
fi

# --- Gate 2: verdict is APPROVE ----------------------------------------------------
# Gates 2 and 4 read the payload. With no parseable verdict, gate 1 has already said the
# real reason -- repeating it as three failures buries it.
if [ "$payload" != "null" ]; then
  v=$(jq -r '.verdict // ""' <<<"$payload")
  [ "$v" = "APPROVE" ] || add_fail "gate2: verdict is '${v:-none}', not APPROVE"
fi

# --- Gate 3: comment author is the authenticated user ------------------------------
if [ "$n_verdicts" -eq 1 ]; then
  ca=$(jq -r '.[0].author' <<<"$comments")
  [ "$ca" = "$me" ] || add_fail "gate3: verdict written by '${ca}', not by authenticated user '${me}'"
fi

# --- Gate 4: head SHA unchanged since review ---------------------------------------
if [ "$payload" != "null" ]; then
  psha=$(jq -r '.head_sha // ""' <<<"$payload")
  if [ "$psha" != "$head_sha" ]; then
    add_fail "gate4: verdict reviewed ${psha:0:8}, live head is ${head_sha:0:8} -- commits pushed since review"
  fi
fi

# --- Gate 5: live checks ------------------------------------------------------------
checks=$(gh pr view "$PR" --repo "$REPO" --json statusCheckRollup \
  --jq '[.statusCheckRollup[]? | {name: (.name // .context), status: (.status // "COMPLETED"), conclusion: (.conclusion // .state)}]')
bad=$(jq -r '[.[] | select((.conclusion // "" | ascii_upcase) as $c | ($c != "SUCCESS" and $c != "NEUTRAL" and $c != "SKIPPED"))] | map(.name) | join(", ")' <<<"$checks")
pending=$(jq -r '[.[] | select((.status // "" | ascii_upcase) != "COMPLETED")] | map(.name) | join(", ")' <<<"$checks")
[ -z "$pending" ] || add_fail "gate5: checks still pending: ${pending}"
[ -z "$bad" ] || add_fail "gate5: checks not passing: ${bad}"

# --- Gate 6: mergeability, two-phase ------------------------------------------------
if [ "$mstate" = "dirty" ]; then
  add_fail "gate6: mergeable_state is 'dirty' -- the branch has conflicts"
elif [ "$PHASE" = "pre" ]; then
  # "blocked" here means "needs the approving review we are about to give".
  case "$mstate" in
    clean|has_hooks|blocked|unstable) : ;;
    *) add_fail "gate6(pre): mergeable_state '${mstate}' is not mergeable" ;;
  esac
  [ "$mergeable" = "true" ] || add_fail "gate6(pre): GitHub reports mergeable=${mergeable}"
else
  case "$mstate" in
    clean|has_hooks) : ;;
    *) add_fail "gate6(post): mergeable_state '${mstate}', expected clean after approval" ;;
  esac
fi

# --- Gate 7: review state and draft --------------------------------------------------
cr=$(gh api --paginate "repos/${REPO}/pulls/${PR}/reviews" \
  --jq '[.[] | select(.state == "CHANGES_REQUESTED") | .user.login]' | jq -s 'add // [] | join(", ")' -r)
[ -z "$cr" ] || add_fail "gate7: changes requested by ${cr}"
[ "$draft" = "false" ] || add_fail "gate7: pull request is a draft"

# --- Gate 8: repository policy --------------------------------------------------------
cfg=".shipyard.yml"
get_cfg() { [ -f "$cfg" ] && sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" "$cfg" | head -1 | tr -d '"'"'"' ' || true; }
auto_merge=$(get_cfg auto_merge); auto_merge="${auto_merge:-true}"
behaviour_diff=$(get_cfg behaviour_diff); behaviour_diff="${behaviour_diff:-warn}"
allowed=$(get_cfg auto_merge_update_types); allowed="${allowed:-[patch, minor]}"

[ "$auto_merge" != "false" ] || add_fail "gate8: .shipyard.yml sets auto_merge: false"

utype=$(jq -r '.dependency.update_type // ""' <<<"$payload")
if [ -n "$utype" ]; then
  case "$allowed" in
    *"$utype"*) : ;;
    *) add_fail "gate8: update_type '${utype}' not in auto_merge_update_types ${allowed}" ;;
  esac
fi
if [ "$behaviour_diff" = "block" ] && [ "$(jq -r '.evidence.rung3 // ""' <<<"$payload")" = "diff" ]; then
  add_fail "gate8: rung3 reported a behaviour diff and behaviour_diff is 'block'"
fi

# --- Report ---------------------------------------------------------------------------
n_fail=${#fails[@]}
self_approval=false
[ "$author" = "$me" ] && self_approval=true

if [ "$n_fail" -eq 0 ] && [ "$PHASE" = "post" ]; then
  mkdir -p .git/shipyard
  printf '%s' "$(date -u +%s)" > ".git/shipyard/${PR}-${head_sha}.pass"
fi

jq -n \
  --arg repo "$REPO" --arg pr "$PR" --arg phase "$PHASE" \
  --arg head "$head_sha" --arg author "$author" --arg me "$me" \
  --arg mstate "$mstate" --argjson self_approval "$self_approval" \
  --argjson payload "$payload" \
  --argjson fails "$(printf '%s\n' "${fails[@]+"${fails[@]}"}" | jq -R . | jq -s 'map(select(. != ""))')" \
  '{repo: $repo, pr: ($pr|tonumber), phase: $phase, head_sha: $head,
    author: $author, authenticated_as: $me,
    self_approval_applies: $self_approval,
    mergeable_state: $mstate,
    verdict: ($payload.verdict // null),
    follow_ups: ($payload.follow_ups // []),
    failures: $fails,
    passed: (($fails | length) == 0)}'

[ "$n_fail" -eq 0 ]
