#!/usr/bin/env python3
"""Scrub recorded pi-acp fixtures for committing:
  - drop the pi startup-banner agent_message_chunk (pi vX + Skills/Prompts/Extensions dump)
  - drop the personal `skill:*` entries from available_commands_update (keep built-ins)
  - rewrite absolute local paths to stable placeholders (/repo, /home/user)
Operates in place on the given *.jsonl files.
"""
import json, os, sys

WORKTREE = "/Users/le/.worktrees/makit/when-we-migrated-to-pi-acp"
HOME = "/Users/le"

def scrub_paths(s: str) -> str:
    return s.replace(WORKTREE, "/repo").replace(HOME, "/home/user")

def is_banner(update: dict) -> bool:
    if update.get("sessionUpdate") != "agent_message_chunk":
        return False
    c = update.get("content")
    txt = c.get("text", "") if isinstance(c, dict) else ""
    return txt.startswith("pi v") and "## Skills" in txt

def scrub_line(obj: dict):
    if obj.get("t") == "update":
        u = obj["update"]
        if is_banner(u):
            return None  # drop the whole banner update
        if u.get("sessionUpdate") == "available_commands_update":
            cmds = u.get("availableCommands") or []
            u["availableCommands"] = [c for c in cmds if not str(c.get("name", "")).startswith("skill:")]
    return obj

def main():
    for path in sys.argv[1:]:
        out = []
        for line in open(path):
            if not line.strip():
                continue
            obj = scrub_line(json.loads(line))
            if obj is not None:
                out.append(scrub_paths(json.dumps(obj)))
        with open(path, "w") as f:
            f.write("\n".join(out) + "\n")
        print(f"scrubbed {path} ({len(out)} lines)")

if __name__ == "__main__":
    main()
