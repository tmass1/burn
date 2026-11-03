#!/usr/bin/env python3
"""Claude Code hook (PreToolUse on Bash, set up in .claude/settings.json): Burn's site deploys only through
scripts/deploy_site.py.

It blocks a raw `wrangler deploy`, `wrangler versions deploy` or `wrangler pages deploy` and points at the script, and
asks Tommy before `wrangler rollback` or `deploy_site.py --yes`. It reads a command the way a shell splits it, so a
deploy named in a quoted string, a heredoc or a grep pattern goes through. It's a guard against mistakes, not a
security boundary, and it lets through anything it can't read as a deploy.
"""
from __future__ import annotations

import json
import re
import shlex
import sys
from typing import List, Optional, Tuple

BLOCK = ("Burn's site deploys only through scripts/deploy_site.py, which first checks that this branch has everything "
         "already live. Run `scripts/deploy_site.py --check` (make deploy-check), show Tommy the whole output, and "
         "deploy only when he names the target. docs/deploying.md explains it; AGENTS.md has the rule.")
ASK_ROLLBACK = ("This rolls back Burn's live site. Rollbacks are Tommy's call: allow it only if he asked for this one. "
                "docs/deploying.md has the steps.")
ASK_YES = ("deploy_site.py --yes deploys without its terminal prompts. Allow it only if Tommy said yes in chat to this "
           "deploy and named its target (production or staging).")

SHELLS = {"sh", "bash", "zsh", "dash", "ksh"}
WRAPPERS = {"sudo", "env", "time", "command", "exec", "nohup", "nice", "caffeinate", "xargs"}
RUNNERS = {"npx", "bunx", "pnpx"}
SUBCOMMAND_RUNNERS = {"pnpm": {"dlx", "exec"}, "yarn": {"dlx", "exec"}, "npm": {"exec", "x"}, "bun": {"x"}}
# Runner and wrangler options that take a value as the next word.
VALUE_FLAGS = {"-p", "--package", "-c", "--call", "--config", "-e", "--env", "--cwd", "--env-file", "--name",
               "--project-name", "--branch", "--message", "-m"}
DENY_SUBCOMMANDS = (("deploy",), ("publish",), ("versions", "deploy"), ("pages", "deploy"), ("pages", "publish"),
                    ("pages", "deployment", "create"), ("triggers", "deploy"))
ASK_SUBCOMMANDS = (("rollback",), ("deployments", "rollback"))
API_WRITE = re.compile(r"(^|\s)(-X|--request)\s*=?\s*(PUT|POST|PATCH|DELETE)\b|(^|\s)(-d|--data\S*|-F|--form|-T|--upload-file)(\s|=|$)")

Decision = Optional[Tuple[str, str]]  # ("deny" | "ask", reason)
RANK = {None: 0, "ask": 1, "deny": 2}


def worst(decisions) -> Decision:
    best: Decision = None
    for decision in decisions:
        if decision and RANK[decision[0]] > RANK[best[0] if best else None]:
            best = decision
    return best


def base(word: str) -> str:
    return word.rsplit("/", 1)[-1]


def strip_heredocs(command: str) -> str:
    """Drops heredoc bodies: they're data (a commit message, a file), not commands."""
    out, ends = [], []
    for line in command.split("\n"):
        if ends:
            if line.strip() == ends[0]:
                ends.pop(0)
            continue
        out.append(line)
        ends += [m.group(2) for m in re.finditer(r"(?<!<)<<-?(?!<)\s*(['\"]?)([A-Za-z_][\w-]*)\1", line)]
    return "\n".join(out)


def substitutions(command: str) -> List[str]:
    """The insides of $(…) and `…` that a shell would run, including inside double quotes."""
    found, i, single, double = [], 0, False, False
    while i < len(command):
        c = command[i]
        if c == "\\" and not single:
            i += 2
            continue
        if c == "'" and not double:
            single = not single
        elif c == '"' and not single:
            double = not double
        elif not single and command.startswith("$(", i):
            depth, j = 1, i + 2
            while j < len(command) and depth:
                depth += {"(": 1, ")": -1}.get(command[j], 0)
                j += 1
            found.append(command[i + 2:j - 1])
            i = j
            continue
        elif not single and c == "`":
            j = command.find("`", i + 1)
            if j < 0:
                break
            found.append(command[i + 1:j])
            i = j + 1
            continue
        i += 1
    return found


def simple_commands(command: str) -> List[List[str]]:
    lexer = shlex.shlex(command.replace("\n", " ; "), posix=True, punctuation_chars=";&|()<>")
    lexer.whitespace_split = True
    lexer.commenters = ""
    commands, words = [], []
    for token in lexer:
        if token and all(ch in ";&|()<>" for ch in token):
            if words:
                commands.append(words)
            words = []
        else:
            words.append(token)
    if words:
        commands.append(words)
    return commands


def skip_flags(words: List[str]) -> List[str]:
    while words and words[0].startswith("-"):
        flag = words.pop(0)
        if flag == "--":
            break
        if flag in VALUE_FLAGS and words:
            words.pop(0)
    return words


def judge(words: List[str], depth: int) -> Decision:
    words = list(words)
    while words and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]) or base(words[0]) in WRAPPERS):
        words.pop(0)
        while words and words[0].startswith("-"):
            words.pop(0)
    if not words:
        return None
    head = base(words[0])

    if head in SHELLS:
        for i, word in enumerate(words[1:-1], start=1):
            if re.fullmatch(r"-[a-zA-Z]*c[a-zA-Z]*", word):
                return assess(words[i + 1], depth + 1)
        return None
    if head == "eval":
        return assess(" ".join(words[1:]), depth + 1)
    if head in ("curl", "wget", "xh", "http"):
        joined = " ".join(words)
        if "api.cloudflare.com" in joined and re.search(r"/workers/scripts/|/pages/projects/|/deployments", joined) \
                and API_WRITE.search(joined):
            return ("deny", BLOCK)
        return None

    if head in RUNNERS or (head in SUBCOMMAND_RUNNERS and len(words) > 1 and words[1] in SUBCOMMAND_RUNNERS[head]):
        # `npx -c '<command>'` runs a whole command line.
        for i, word in enumerate(words[:-1]):
            if word in ("-c", "--call"):
                return assess(words[i + 1], depth + 1)
    if head in RUNNERS:
        words = skip_flags(words[1:])
    elif head in SUBCOMMAND_RUNNERS and len(words) > 1 and words[1] in SUBCOMMAND_RUNNERS[head]:
        words = skip_flags(words[2:])
    elif head in ("pnpm", "yarn") and len(words) > 1 and base(words[1]).startswith("wrangler"):
        words = words[1:]
    if not words:
        return None
    head = base(words[0])

    if head == "deploy_site.py" or (head.startswith("python") and len(words) > 1 and base(words[1]) == "deploy_site.py"):
        return ("ask", ASK_YES) if "--yes" in words else None
    if head != "wrangler" and not head.startswith("wrangler@"):
        return None
    rest = words[1:]
    positional = []
    while rest:
        word = rest.pop(0)
        if word.startswith("-"):
            if word in VALUE_FLAGS and rest:
                rest.pop(0)
            continue
        positional.append(word)
    if any(tuple(positional[:len(sub)]) == sub for sub in DENY_SUBCOMMANDS):
        return ("deny", BLOCK)
    if any(tuple(positional[:len(sub)]) == sub for sub in ASK_SUBCOMMANDS):
        return ("ask", ASK_ROLLBACK)
    return None


def assess(command: str, depth: int = 0) -> Decision:
    if depth > 5:
        return None
    command = strip_heredocs(command)
    try:
        found = [judge(words, depth) for words in simple_commands(command)]
    except ValueError:
        # Unbalanced quotes: a shell wouldn't run it either, but err on the side of the rule.
        if re.search(r"\bwrangler(@\S+)?\s+(\S+\s+)?(deploy|publish)\b", command):
            return ("deny", BLOCK)
        found = []
    found += [assess(inner, depth + 1) for inner in substitutions(command)]
    return worst(found)


def main() -> int:
    try:
        event = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    if event.get("tool_name") != "Bash":
        return 0
    decision = assess(str((event.get("tool_input") or {}).get("command") or ""))
    if decision:
        kind, reason = decision
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": kind,
                                                 "permissionDecisionReason": reason}}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
