# Adding a package

## 1. Pick a stage

Read [stages.md](stages.md) and name the package `<stage>-<thing>`. Cross-stage packages
use the `shipyard-` prefix. The name goes in the install ref, so it is documentation for
whoever reads someone else's `apm.yml`.

## 2. Scaffold

```bash
cd packages
apm init <name> -y --target claude
```

Then set `version: 0.1.0`, add `license: MIT`, `repository`, and `keywords`, and write the
`description` as a sentence someone could act on — it is what a consumer sees.

## 3. Choose primitives

| You want | Author | Lands as |
|---|---|---|
| A user-typed entry point | `.apm/prompts/x.prompt.md` | `/x` slash command |
| A procedure the model follows | `.apm/skills/x/SKILL.md` | skill |
| A worker with its own context | `.apm/agents/x.agent.md` | subagent |
| A deterministic guardrail | `.apm/hooks/x.json` | merged into `settings.json` |
| An always-on rule | `.apm/instructions/x.instructions.md` | `.claude/rules/` |

Commands are entry points, skills are procedures, subagents are workers, hooks are
guardrails. Keep the command thin — resolve `$ARGUMENTS` and hand off — so the same
procedure is reachable by typing the command *and* by describing the intent.

## 4. Write the description for discovery

A skill is model-invoked on its `description`. Name **situations, not commands**:

> Use when reviewing a pull request to decide whether it is safe to merge…

not

> Run /review-pr to review a PR.

The second only fires when the user already knows the command exists, which defeats half
the point. Keep it under 1024 characters.

## 5. Keep `SKILL.md` small

Under ~500 lines. Overflow goes in `references/<topic>.md`, loaded explicitly from the body
with a `LOAD references/<file>` line. Every harness pays context for an oversized body.

## 6. Scripts over prose for anything deterministic

If a step has one right answer — an API call, a parse, a set of gates — write it as a script
in `scripts/` and have the skill run it. Prose instructions get followed approximately;
scripts get followed exactly. The eight merge preconditions are a script for this reason.

## 7. Declare dependencies

```yaml
dependencies:
  apm:
    - ../shipyard-contracts                                     # sibling package
    - mattpocock/skills/skills/engineering/code-review#v1.2.3    # upstream, pinned to a tag
```

**Always pin third-party packages to a tag.** A dependency is prompt text that will run in
every repo that installs you; a floating ref means it can change under you.

## 8. Verify

```bash
apm install --dry-run      # resolves, scans
apm compile --validate     # every primitive parses
apm deps tree              # the graph is what you think it is
```

Then add the package to `apm.yml` at the repo root and to the table in `stages.md`.
