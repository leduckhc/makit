#!/usr/bin/env python3
"""Rewrite legacy `SPEC-<NN>` references to `SPEC-<slug>`, and spec paths to their
new filenames.

Six numbers were double-booked by two unrelated features each, so a global
substitution would silently mislabel about a quarter of all references. This
script therefore resolves every occurrence of an ambiguous number from evidence,
and REFUSES TO WRITE ANYTHING while a single site is unresolved. A wrong rewrite
is worse than no rewrite: it reads as fact.

Evidence, most specific first:
  1. an explicit override for one file:line,
  2. discriminating terms on the line itself,
  3. the subject of the file the line sits in,
  4. a per-number default — every use of which is reported for review.

Usage: rewrite_spec_refs.py [--apply | --list-files]

`--list-files` prints the paths this script reads, one per line. A test then
compares them with the paths the naming guard scans.
"""
import json
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAP = json.loads((ROOT / "scripts/spec-migration/map.json").read_text())

# Trees that are checkouts of other repositories, or build output.
# Only the VENDOR subtree of .agents/skills is third-party. makit's own skills
# live beside it and must be rewritten, or retired ids creep back in through
# them — which is exactly what happened after #168.
VENDORED = (".pi/git/", ".agents/skills/vendor/", "signatures/", "server/dist/",
            "node_modules/",
            # The migration's own record keeps the retired names on purpose. Rewriting
            # it would erase the mapping that makes this script auditable.
            "scripts/spec-migration/")
TEXT_EXT = {
    ".dart", ".ts", ".js", ".md", ".html", ".sh", ".yaml", ".yml", ".json",
    ".swift", ".entitlements", ".pbxproj", ".plist",
}

# number -> {slug: [discriminating terms]}, for the six that were double-booked.
# Terms match on word boundaries. A term that appears in both features is useless
# here, and a term that hides inside a common word is worse: `cli` inside `client`
# sent "this client is watching docs" to the wrong spec on the first run.
AMBIGUOUS = {
    "07": {
        # The async-loop doc was only ever "scoped"; actionable-notifications plus
        # background-wake implemented it. Code references mean the implemented one.
        "background-wake-notifications": [
            "push", "apns", "wake", "woken", "background", "silent", "force-quit",
            "killed", "replay", "drain", "registrar", "bearer", "deviceregistry",
            "w2", "w4", "a6",
        ],
        "notifications-async-loop": ["async loop", "async-loop"],
    },
    "37": {
        "performance-metrics-dashboard": [
            "agentpid", "pid", "tier 1", "tier 2", "metric", "metrics", "sampler",
            "sample", "samples", "ledger", "cpu", "chart", "charts", "collector",
            "watcher", "watched", "cadence", "loopback", "performance", "dashboard",
            "1 hz", "ps", "decision 4", "decision 5", "decision 6", "decision 7",
            "decision 11", "decision 16", "d6", "leak",
        ],
        "context-usage": [
            "session.usage", "per-category", "context", "usage", "occupancy",
            "window", "footer", "pill", "panel", "compact", "ring ladder",
            "golden", "goldens", "cost", "spend",
        ],
    },
    "38": {
        "pending-queue-edit-reorder": [
            "queue", "queued", "pending", "reorder", "promote", "draft", "steer",
            "ghost", "bubble", "composer", "trailer", "palette", "placement",
        ],
        "pr-actions-next-step-bar": [
            "pr", "pull request", "next-step", "next step", "checks", "merge",
            "merged", "prstatus", "prsignal", "forge", "github", "branch",
            "confirm dialog", "discard",
        ],
    },
    "46": {
        "cli-as-client": [
            "credential", "capability", "capabilities", "caps", "lineage",
            "handoff", "spawn", "spawned", "fork", "forked", "bearer",
            "principal", "exit code", "exit codes", "automation", "argv",
            "terminal", "verb", "u2", "u3", "u4", "t11", "t14", "t15", "t16",
            "c1", "c3", "c4", "d10", "d13", "d17", "gate", "gates",
        ],
        "doc-preview": [
            "doc", "docs", "document", "markdown", "publish", "publication",
            "grant", "preview", "render", "d7", "d11", "d15",
        ],
    },
    "48": {
        "status-and-activity": [
            "status", "activity", "notice", "toast", "badge", "severity",
            "unread", "snackbar", "messenger", "log line", "statuscenter",
            "obstruction", "language",
        ],
        "per-repo-settings": [
            "repo", "repos", "repository", "per-repo", "forge", "forgejo",
            "gitea", "worktree root", "base branch", "monogram", "provider",
            "checked out", "checkout", "pinned repo", "projects.json",
            "d12", "d13", "d14", "d15", "d16", "d17", "d18", "d19", "d20",
        ],
    },
    "51": {
        "preview-groups": [
            "preview", "group", "groups", "board", "tab", "disposable",
            "appearance", "layout", "sidebar",
        ],
        "target-branch": [
            "target", "base branch", "lands", "land", "diff", "ahead", "behind",
        ],
    },
}

# Where the line's own words are inconclusive, the file's subject settles it.
# Every rule below was chosen by reading the sites it covers:
#   - status-and-activity D3 IS the "capture before await" hazard, so the
#     split_view / client_commands D3 comments belong to it.
#   - per-repo-settings owns the primed decisions (D3', D4', D8') and D12-D23, so
#     manager.ts's worktree-root and PR-checkout comments belong to it.
#   - `Tier 2`, `agentPid` and `decision N` appear only in the metrics dashboard;
#     `session.usage` and `per-category` appear only in context-usage. Verified by
#     grepping both specs, not assumed.
AMB_PATHS = {
    "07": {
        "notifications-async-loop": [
            "docs/specs/20260708-000701-SPEC-notifications-async-loop.md",
        ],
        "_DEFAULT": "background-wake-notifications",
    },
    "37": {
        "context-usage": [
            "app/lib/ui/composer/context_usage",
            "app/test/ui/composer/context_usage",
            "app/test/ui/composer/composer_footer",
            "app/test/composer_footer_space_test.dart",
            "mockups/session-identity.html",
            "server/src/bridge",
            "app/lib/ui/session/session_identity.dart",
            "app/lib/ui/session/session_screen.dart",
            "app/test/session_identity_widget_test.dart",
            "docs/specs/20260805-003700-SPEC-context-usage",
            "docs/specs/20260806-004000-SPEC-composer-footer-space",
            "mockups/composer-footer-space.html",
            ".pi/settings.json",
        ],
        "performance-metrics-dashboard": [
            "server/src/metrics/",
            "app/lib/desktop/metrics/",
            "app/lib/store/metrics.dart",
            "server/src/ws/auth_gate.ts",
            "server/test/ws/auth_gate.test.ts",
            "docs/specs/20260803-003700-SPEC-performance-metrics-dashboard",
        ],
        "_DEFAULT": "performance-metrics-dashboard",
    },
    "38": {
        "pr-actions-next-step-bar": [
            "app/lib/ui/widgets/pr_signals",
            "app/lib/ui/home/repo_chips.dart",
            "app/test/ui/widgets/pr_signals",
            "app/test/ui/session/session_pr_test.dart",
            "app/test/desktop/chat/pr_bar_test.dart",
            "app/test/theme_contrast_test.dart",
            "app/tool/pr_bar_demo.dart",
            "mockups/pr-actions-next-step.html",
            "docs/specs/20260806-003800-SPEC-pr-actions-next-step-bar",
            "server/src/github/",
            "server/src/repo_service.ts",
            "server/src/manager.ts",
            "server/src/manager.test.ts",
            "server/test/ws/pr_commands.test.ts",
            "server/test/ws/repos_refresh_on_turn_end.test.ts",
        ],
        "pending-queue-edit-reorder": [
            "app/lib/ui/composer/pending_queue",
            "app/lib/ui/composer/slash_palette.dart",
            "app/lib/ui/session/chat_transcript.dart",
            "app/lib/store/prefs/",
            "app/integration_test/",
            "docs/specs/20260802-003800-SPEC-pending-queue-edit-reorder",
        ],
        "_DEFAULT": "pending-queue-edit-reorder",
    },
    "46": {
        "doc-preview": [
            "server/src/docs/",
            "app/lib/ui/docs/",
            "app/lib/store/docs.dart",
            "app/lib/store/connection.dart",
            "app/test/ui/docs/",
            "app/test/ui/home/worktree_row_docs_watch_test.dart",
            "mockups/doc-preview.html",
            "docs/specs/20260809-004600-SPEC-doc-preview.md",
        ],
        "cli-as-client": [
            "server/src/cli/",
            "server/src/index.ts",
            "server/src/adapters/stub",
            "server/test/protocol/",
            "docs/specs/20260807-004600-SPEC-cli-as-client",
        ],
        "_DEFAULT": "cli-as-client",
    },
    "48": {
        "per-repo-settings": [
            "app/lib/desktop/settings/",
            "app/test/desktop/settings/",
            "app/lib/ui/home/repo_monogram.dart",
            "app/lib/ui/widgets/lands_in_picker.dart",
            "server/src/repo_settings",
            "server/src/forge/",
            "server/src/git.test.ts",
            "server/src/git.pr_checkout.test.ts",
            "server/src/manager.ts",
            "server/test/ws/repo_settings_commands.test.ts",
            "mockups/forge-",
            "docs/specs/20260810-004800-SPEC-per-repo-settings",
        ],
        "status-and-activity": [
            "app/lib/status/",
            "app/test/status/",
            "app/lib/desktop/chat/split_view.dart",
            "app/lib/ui/composer/client_commands.dart",
            "app/lib/notifications/",
            "docs/NOTIFICATIONS.md",
            "mockups/status-language-ios-macos.html",
            "mockups/notice-copy-and-review.html",
            "docs/specs/20260809-004800-SPEC-status-and-activity",
            "docs/specs/20260810-004900-SPEC-notice-layer",
        ],
        "_DEFAULT": "status-and-activity",
    },
    "51": {
        "target-branch": [
            "server/src/ws/commands/worktree.ts",
            "mockups/base-branch.html",
            "docs/specs/20260811-005100-SPEC-target-branch.md",
        ],
        "preview-groups": [
            "app/lib/desktop/chat/groups/",
            "app/lib/store/prefs/",
            "app/test/desktop/settings/appearance_layout_test.dart",
        ],
        "_DEFAULT": "preview-groups",
    },
}

# number -> slug, for the numbers that only ever meant one thing.
UNIQUE = {}
for r in MAP:
    if r["kind"] != "spec":
        continue
    n = r["legacy"][5:]
    if n not in AMBIGUOUS:
        UNIQUE[n] = r["slug"]

# old filename -> new filename, for markdown links and prose paths.
PATHS = {r["old"]: r["new"] for r in MAP}
PATHS["2026-08-09-PORTS-P2c-P4-STATUS.md"] = "20260809-000000-PORTS-P2c-P4-STATUS.md"

# Sites that needed a human. Each was read before it was written down.
OVERRIDES = json.loads((ROOT / "scripts/spec-migration/overrides.json").read_text())


def _term_re(term):
    """Match a term on word boundaries, so `cli` never fires inside `client`."""
    left = r"\b" if term[0].isalnum() else ""
    right = r"\b" if term[-1].isalnum() else ""
    return re.compile(left + re.escape(term) + right)


TERMS = {num: {slug: [_term_re(t) for t in terms] for slug, terms in cands.items()}
         for num, cands in AMBIGUOUS.items()}

SPEC_RE = re.compile(r"\bSPEC-(\d{1,2})\b")

defaulted = defaultdict(list)


def classify(num, line, relpath, lineno):
    """Resolve one ambiguous occurrence, most specific evidence first."""
    key = f"{relpath}:{lineno}"
    if key in OVERRIDES:
        return OVERRIDES[key]

    low = line.lower()
    scores = {slug: sum(1 for r in res if r.search(low))
              for slug, res in TERMS[num].items()}
    ranked = sorted(scores.items(), key=lambda kv: -kv[1])
    if ranked[0][1] > 0 and ranked[0][1] != ranked[1][1]:
        return ranked[0][0]

    rules = AMB_PATHS.get(num)
    if not rules:
        return None
    for slug, prefixes in rules.items():
        if slug == "_DEFAULT":
            continue
        if any(relpath.startswith(p) for p in prefixes):
            return slug
    fallback = rules.get("_DEFAULT")
    if fallback:
        defaulted[num].append((relpath, lineno, fallback, line.strip()[:110]))
        return fallback
    return None


def tracked_files():
    out = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True).stdout
    for rel in out.splitlines():
        if rel.startswith(VENDORED):
            continue
        if Path(rel).suffix not in TEXT_EXT:
            continue
        yield rel


def main():
    if "--list-files" in sys.argv:
        for rel in tracked_files():
            print(rel)
        return 0

    apply = "--apply" in sys.argv
    unresolved = []
    decisions = defaultdict(list)
    edits = 0

    for rel in tracked_files():
        path = ROOT / rel
        try:
            text = path.read_text()
        except (UnicodeDecodeError, FileNotFoundError):
            continue
        original = text

        # 1. spec paths first: a link's filename holds a number that is not a
        #    reference token, and must not be rewritten as one.
        for old, new in PATHS.items():
            if old in text:
                text = text.replace(old, new)

        # 2. reference tokens, line by line, so an ambiguous one sees its context.
        lines = text.split("\n")
        for i, line in enumerate(lines):
            if "SPEC-" not in line:
                continue

            def sub(m, _i=i, _line=line):
                num = m.group(1).zfill(2)
                if num in UNIQUE:
                    return "SPEC-" + UNIQUE[num]
                if num in AMBIGUOUS:
                    slug = classify(num, _line, rel, _i + 1)
                    if slug is None:
                        unresolved.append((rel, _i + 1, num, _line.strip()[:160]))
                        return m.group(0)
                    decisions[num].append((rel, _i + 1, slug, _line.strip()[:110]))
                    return "SPEC-" + slug
                unresolved.append((rel, _i + 1, num, _line.strip()[:160]))
                return m.group(0)

            lines[i] = SPEC_RE.sub(sub, line)
        text = "\n".join(lines)

        if text != original:
            edits += 1
            if apply:
                path.write_text(text)

    print(f"files needing edits: {edits}")
    print(f"ambiguous sites resolved: {sum(len(v) for v in decisions.values())}")
    for num in sorted(decisions):
        per = defaultdict(int)
        for _, _, slug, _ in decisions[num]:
            per[slug] += 1
        print(f"  SPEC-{num}: " + ", ".join(f"{s}={c}" for s, c in sorted(per.items())))
    print(f"UNRESOLVED: {len(unresolved)}")
    for rel, ln, num, line in unresolved[:60]:
        print(f"  {rel}:{ln} [SPEC-{num}] {line}")

    total_def = sum(len(v) for v in defaulted.values())
    print(f"\nfell through to a per-number default: {total_def}")
    for num in sorted(defaulted):
        per = defaultdict(int)
        for _, _, slug, _ in defaulted[num]:
            per[slug] += 1
        print(f"  SPEC-{num}: " + ", ".join(f"{s}={c}" for s, c in sorted(per.items())))

    json.dump({f"{r}:{l}": {"num": n, "line": t} for r, l, n, t in unresolved},
              open("/tmp/unresolved.json", "w"), indent=1)
    json.dump({num: [{"file": r, "line": l, "slug": s, "text": t} for r, l, s, t in v]
               for num, v in defaulted.items()},
              open("/tmp/defaulted.json", "w"), indent=1)

    if unresolved and apply:
        print("\nREFUSING TO WRITE: unresolved sites remain.", file=sys.stderr)
        return 1
    if apply:
        print(f"\napplied to {edits} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
