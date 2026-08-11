# SPEC-46 P1: Docs — Preview HTML and Markdown (feat/serving-html)

## Status
✅ **Verified on device.** 21 commits, 1243 server tests, 2061 app tests. All green.

## What ships

### Desktop & App
- **Docs screen** (Option A from the spec): grouped by repo/worktree, searchable by title and path, filterable (All / Mockups / Specs / Changed)
- **Markdown preview** in-app: front-matter (Status/Priority/Branch) hoisted above the title, reader-width toggle for desktop
- **HTML preview**: local clients open in Safari/Edge via `docs.open` (no serving). Remote clients publish and share via tailnet grant.

### Server
- **D1 rev 2 — Everything git doesn't ignore**: `git ls-files --cached --others --exclude-standard` (69 docs in teachme, 143 in makit), with fallback to the old allowlist (`mockups/`, `docs/`, `*.md` at root) when git cannot answer
- **D8 rev 2 — Where the viewer is decides how**: loopback client → `docs.open` → OS opener. Tailnet client → publish → grant → URL. No webview.
- **D9/D10/D15**: tailnet-bound HTTP listener, lazy on first publish, capability URL in the path (no bearer), TTL-gated grants
- **D11**: snapshot streaming, indexed by worktree, enriched with mtime, status, and changed flag

### Fixes from ocr review
- `serverIsLocal` reset on reconnect (race window between local→remote switch)
- `markdownError` plumbed through FutureBuilder
- Listener bind/close races coalesced
- Popover crash when available height < 96pt (fixed with Flexible + ConstrainedBox)
- All three `hello.ack` paths now send `isLocal`
- `docs.open` refuses win32 (argv-only, no shell)
- Defensive error handling in scan loop

## Verified behavior (device test)
- ✅ teachme shows **69 docs** (was 3 with D1 rev 1)
- ✅ Popover **search field** works, filters title+path
- ✅ Paths are **relative** in popover, **absolute** in Docs screen
- ✅ **Open in browser** button on local client (no serve)
- ✅ Edge opened HTML without any HTTP listener for this profile
- ✅ `hello.ack` carries `isLocal: true` on loopback

## Known non-issues
- `flutter_tester` WebSocket concurrency flake (~19 failures per full-suite run, all `: loading ` entries, zero real assertion failures)
- ocr found 48 issues: 5 high (all fixed + tests), 19 medium (left for follow-up), 24 low (left for follow-up)

## Test coverage
- Server: 1243/1243 pass (includes new race, timeout, coalesce, arg-passing tests)
- App: 2061 pass (includes new D8 rev 2 local/remote split tests)
- Both: typecheck clean, analyze clean

## Not in P1 (deferred to P2+)
- P2: Canvas (doc beside chat, live-reload)
- P3: HTML in-app webview
- P4+: VCS annotations, publishing from within the preview

## Branch readiness
- All commits squashed per project style? No — kept logical units for review
- PR template required? Check with maintainers
- Needs rebase? No — all commits since P1a exist only in this branch

## For reviewers
- Start with `d627c229` (SPEC-46 P1a) to see the security boundary
- `00317d01` has the D1 rev 2 restructure (git vs walk)
- `20a1cd8d` is the major refactor (ocr fixes + defensiveness)
- `8495844a` wires D8 rev 2 (local OS opener)
