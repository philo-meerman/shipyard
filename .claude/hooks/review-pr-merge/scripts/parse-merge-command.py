#!/usr/bin/env python3
"""Decide whether a Bash tool payload is a real `gh pr merge` invocation.

Reads the PreToolUse JSON payload on stdin. Prints one of:

    ALLOW            not a merge invocation
    MERGE <number>   a merge of that PR
    MERGE            a merge with no identifiable PR number

A plain substring test is not enough. `grep -r "gh pr merge" docs/` contains the string
but merges nothing, and blocking it would train the user to switch the hook off. So:
blank out quoted segments, then require the command to sit at a command position.

Fails closed: an unparseable payload prints `MERGE`, because a merge we cannot inspect is
one we should not wave through.
"""
import json
import re
import sys

QUOTED = re.compile(r"\"(?:\\.|[^\"\\])*\"|'[^']*'")
INVOCATION = re.compile(
    r"(?:^|[;&|\n(]|&&|\|\|)\s*(?:sudo\s+)?gh\s+pr\s+merge\b(.*)", re.M
)
PR_NUMBER = re.compile(r"\s(\d+)\b")


def main() -> None:
    try:
        cmd = json.load(sys.stdin).get("tool_input", {}).get("command", "")
    except Exception:
        print("MERGE")
        return

    if not isinstance(cmd, str) or "gh" not in cmd:
        print("ALLOW")
        return

    stripped = QUOTED.sub(lambda m: " " * len(m.group(0)), cmd)

    match = INVOCATION.search(stripped)
    if not match:
        print("ALLOW")
        return

    number = PR_NUMBER.search(match.group(1))
    print(f"MERGE {number.group(1)}" if number else "MERGE")


if __name__ == "__main__":
    main()
