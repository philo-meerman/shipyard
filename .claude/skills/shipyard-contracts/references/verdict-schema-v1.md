# `shipyard/verdict/v1` — payload reference

## Example

```json
{
  "schema": "shipyard/verdict/v1",
  "verdict": "APPROVE",
  "head_sha": "c62afa48f4dd615bace887e5cfd10c184eea5f4d",
  "reviewed_at": "2026-09-05T14:00:00Z",
  "reviewer": "review-pr-gate@0.1.0",
  "lane": "dependency-bump",
  "author": {
    "login": "dependabot[bot]",
    "association": "CONTRIBUTOR",
    "trusted": true
  },
  "dependency": {
    "name": "pypdf",
    "from": "6.10.2",
    "to": "6.16.1",
    "update_type": "minor"
  },
  "evidence": {
    "rung0": "pass",
    "rung1": "pass",
    "rung2": "pass",
    "rung3": "diff",
    "unit": "pass",
    "unit_relevant": false
  },
  "checks": [{ "name": "CodeQL", "conclusion": "NEUTRAL" }],
  "findings": [],
  "follow_ups": ["pypdf changed extracted text; regenerate embeddings.index"]
}
```

## Fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema` | string | yes | Exactly `shipyard/verdict/v1`. A reader seeing any other value must refuse to act. |
| `verdict` | enum | yes | `APPROVE` \| `BLOCK` \| `NEEDS_HUMAN`. |
| `head_sha` | string | yes | Full 40-char OID of the PR head **at review time**. |
| `reviewed_at` | string | yes | ISO-8601 UTC. |
| `reviewer` | string | yes | `<package>@<version>`. |
| `lane` | enum | yes | `dependency-bump` \| `code-change`. |
| `author` | object | yes | `login` (REST spelling), `association`, `trusted` (bool). |
| `dependency` | object | lane only | Present when `lane == "dependency-bump"`. |
| `evidence` | object | yes | See the ladder below. |
| `checks` | array | yes | `{name, conclusion}` as reported by GitHub at review time. |
| `findings` | array | yes | `{severity, file, line, summary}`. `severity: "blocking"` forces `BLOCK`. |
| `follow_ups` | array | no | Human-readable actions the merge does not perform. |

### `author.login`

Always the **REST API** spelling from `gh api repos/{o}/{r}/pulls/{n} --jq .user.login`
(e.g. `dependabot[bot]`). `gh pr view --json author` reports a different form
(`app/dependabot`) and must not be used here — the two do not compare equal.

### `dependency.update_type`

Derived by comparing `from` and `to` as semver: `major`, `minor`, or `patch`. When the
versions are not parseable as semver, use `unknown`, which no policy may auto-merge.

## The evidence ladder

Each rung is `pass` \| `fail` \| `skip` \| `unavailable`, except as noted.

| Key | Rung | Meaning |
|---|---|---|
| `rung0` | Resolves | Dependencies install and are mutually consistent. |
| `rung1` | Imports | Every affected module imports / the project compiles. |
| `rung2` | Smoke | The app boots and serves its health URL. |
| `rung3` | Boundary | Behaviour at the changed boundary, on base vs head. Values: `pass` (identical), `diff` (differs — reported), `fail`, `skip`, `unavailable`. |
| `unit` | Unit | The repository's own test suite. |
| `unit_relevant` | — | Boolean. `false` means the suite passed but does not exercise the change (e.g. it mocks the changed boundary). |

`unavailable` means the rung **could not run**. Any `unavailable` rung that the repo's
configuration expected to run forces `NEEDS_HUMAN`, never `BLOCK`.

`rung3: "diff"` is not a failure. It records that behaviour changed, which for a bug-fix
release is often the point. Whether a diff blocks is a per-repo policy decision
(`dependency_policy.behaviour_diff`), enforced by the merge gate, not encoded here.

## Verdict derivation

In order; first match wins.

1. Any `findings[].severity == "blocking"` → `BLOCK`.
2. Any rung `fail`, or a required check failed → `BLOCK`.
3. Any expected rung `unavailable`, any check still pending, or `author.trusted == false`
   → `NEEDS_HUMAN`.
4. Otherwise → `APPROVE`.

`unit_relevant: false` never changes the verdict on its own. It is recorded so the merge
gate and the reader can see what the passing suite did and did not prove.
