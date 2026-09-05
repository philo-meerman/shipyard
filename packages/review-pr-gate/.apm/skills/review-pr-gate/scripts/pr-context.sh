#!/usr/bin/env bash
# Collect every fact the review gate needs about a pull request, as one JSON object.
#
# Usage: pr-context.sh <pr-number> [owner/repo]
#
# Facts come from the REST API, not `gh pr view --json`, because:
#   * `gh pr view --json authorAssociation` does not exist -- the call errors.
#   * The endpoints spell the author differently: `gh pr view` says "app/dependabot"
#     where REST says "dependabot[bot]". The verdict records the REST spelling and the
#     merge gate compares against it, so mixing them breaks the trust check silently.
set -euo pipefail

PR="${1:?usage: pr-context.sh <pr-number> [owner/repo]}"
REPO="${2:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"

pr_json=$(gh api "repos/${REPO}/pulls/${PR}")
files_json=$(gh api --paginate "repos/${REPO}/pulls/${PR}/files" --jq '[.[] | {path: .filename, status, additions, deletions}]' | jq -s 'add // []')
commits_json=$(gh api --paginate "repos/${REPO}/pulls/${PR}/commits" --jq '[.[] | {sha: .sha, login: (.author.login // null), verified: .commit.verification.verified}]' | jq -s 'add // []')
reviews_json=$(gh api --paginate "repos/${REPO}/pulls/${PR}/reviews" --jq '[.[] | {user: .user.login, state}]' | jq -s 'add // []')

head_sha=$(jq -r .head.sha <<<"$pr_json")

# statusCheckRollup is only exposed through the GraphQL-backed `gh pr view`, so take
# exactly that one field from it and nothing else.
checks_json=$(gh pr view "$PR" --repo "$REPO" --json statusCheckRollup \
  --jq '[.statusCheckRollup[]? | {name: (.name // .context), status: (.status // "COMPLETED"), conclusion: (.conclusion // .state)}]')

# Existing shipyard verdict comments, so the caller edits rather than duplicates.
verdict_json=$(gh api --paginate "repos/${REPO}/issues/${PR}/comments" \
  --jq '[.[] | select(.body | contains("shipyard:verdict")) | {id, author: .user.login, updated_at}]' | jq -s 'add // []')

# Repo config, if the consuming repo has one.
config_present=false
[ -f .shipyard.yml ] && config_present=true

# Dependabot embeds a compatibility-score badge whose query string is an authoritative
# parse of what changed. Prefer it over inferring the versions from the PR title.
body=$(jq -r '.body // ""' <<<"$pr_json")
badge=$(grep -o 'compatibility_score?[^)"]*' <<<"$body" | head -1 || true)
dep_name=$(sed -n 's/.*dependency-name=\([^&]*\).*/\1/p' <<<"$badge")
dep_from=$(sed -n 's/.*previous-version=\([^&]*\).*/\1/p' <<<"$badge")
dep_to=$(sed -n 's/.*new-version=\([^&]*\).*/\1/p' <<<"$badge")
dep_mgr=$(sed -n 's/.*package-manager=\([^&]*\).*/\1/p' <<<"$badge")

update_type="unknown"
if [ -n "$dep_from" ] && [ -n "$dep_to" ]; then
  update_type=$(python3 -c '
import re, sys
def parts(v):
    m = re.match(r"^v?(\d+)\.(\d+)\.(\d+)", v)
    return tuple(int(x) for x in m.groups()) if m else None
a, b = parts(sys.argv[1]), parts(sys.argv[2])
if not a or not b:
    print("unknown")
elif a[0] != b[0]:
    print("major")
elif a[1] != b[1]:
    print("minor")
elif a[2] != b[2]:
    print("patch")
else:
    print("none")
' "$dep_from" "$dep_to" 2>/dev/null || echo unknown)
fi

# The body carries the full upstream changelog -- often 10KB+ of HTML. Hand back a bounded
# excerpt plus the length, so the caller can decide whether to fetch the rest, rather than
# absorbing all of it unasked.
body_len=${#body}
body_excerpt=$(printf '%s' "$body" | head -c 4000)

jq -n \
  --argjson pr "$pr_json" \
  --argjson files "$files_json" \
  --argjson commits "$commits_json" \
  --argjson reviews "$reviews_json" \
  --argjson checks "$checks_json" \
  --argjson verdicts "$verdict_json" \
  --arg repo "$REPO" \
  --arg head "$head_sha" \
  --argjson config_present "$config_present" \
  --arg body_excerpt "$body_excerpt" \
  --argjson body_len "$body_len" \
  --arg dep_name "$dep_name" \
  --arg dep_from "$dep_from" \
  --arg dep_to "$dep_to" \
  --arg dep_mgr "$dep_mgr" \
  --arg update_type "$update_type" \
  '{
     repo: $repo,
     number: $pr.number,
     title: $pr.title,
     body_excerpt: $body_excerpt,
     body_length: $body_len,
     draft: $pr.draft,
     state: $pr.state,
     head_sha: $head,
     base_ref: $pr.base.ref,
     head_ref: $pr.head.ref,
     is_cross_repository: ($pr.head.repo.full_name != $pr.base.repo.full_name),
     author: {
       login: $pr.user.login,
       association: $pr.author_association,
       is_bot: ($pr.user.type == "Bot")
     },
     mergeable: $pr.mergeable,
     mergeable_state: $pr.mergeable_state,
     files: $files,
     commits: $commits,
     reviews: $reviews,
     checks: $checks,
     existing_verdict_comments: $verdicts,
     shipyard_config_present: $config_present,
     dependency: (if $dep_name == "" then null else {
       name: $dep_name,
       from: $dep_from,
       to: $dep_to,
       package_manager: $dep_mgr,
       update_type: $update_type
     } end)
   }'
