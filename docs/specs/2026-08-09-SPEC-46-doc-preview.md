# SPEC-46 — Docs: preview the HTML and Markdown that live in the repo

**Status:** Draft (P1) · **Priority:** P2 · **Branch:** `feat/serving-html`

Design board: [`mockups/doc-preview.html`](../../mockups/doc-preview.html)

---

## Goal

Read the repo's own artefacts — **27 mockup boards, 70 spec/plan markdowns**, the architecture
shelf — from inside makit, on the phone and on the desktop, without leaving the app to find them
and without asking an agent to open a port.

Today there are two paths and both are bad:

- **Desktop:** ⌘-tab to Finder → hunt `mockups/` → double-click → the file opens in the default
  browser, detached from the branch it belongs to. Two branches' versions of the same mockup
  produce two indistinguishable tabs.
- **Mobile:** ask the agent for `python3 -m http.server`, wait, receive a `100.x:8765` URL, leave
  makit for Safari, lose the link when the session ends — and leave a listener behind that then
  shows up in the **Ports** screen as an orphan. We built a whole feature to clean up after this
  workflow.

## Why this belongs in makit

makit already knows the three things a document catalogue needs and that a file browser does not:
**which worktree owns a file**, **which session last wrote it**, and **when the tree changed**. The
answer is therefore not a file browser — it is the Ports pattern (SPEC-41/42) applied to documents:
a watch-gated host-wide snapshot, grouped repo → worktree → item, with one preview surface and an
explicit, revocable way to reach it from elsewhere.

Three facts make this far cheaper than it looks, and they are the reason the phasing works:

1. **Markdown is already solved.** `flutter_markdown_plus` is a dependency and
   `app/lib/ui/session/chat_message.dart` already renders styled markdown with a code-block
   builder. A spec file is the same content type the transcript renders all day: no new
   dependency, no HTTP, no webview.
2. **Every `mockups/*.html` is self-contained** — inline `<style>`, inline SVG, zero external
   assets (verified across all 27). "Serve a mockup" means serving *one file*, not resolving a
   dependency graph.
3. **The watcher already runs.** `worktree_watcher.ts` watches the tree, so the index needs no
   polling loop of its own.

## Decisions (locked before implementation)

| # | Decision | Why |
| --- | --- | --- |
| D1 | **rev 2. Everything git does not ignore.** The index lists every `.md`/`.html` path from `git ls-files --cached --others --exclude-standard`, so tracked *and* freshly-written untracked docs appear. `.makit/docs.json` `roots` now **narrows** the index to a walk of exactly those directories; a worktree git cannot answer for falls back to rev 1's allowlist. | **rev 1 was `mockups/`, `docs/`, and `*.md` at the root** — an allowlist chosen to avoid traversal and noise. It was measured against the wrong repo: it is *this* repo's layout. On `teachme`, whose docs live in `flutter/learning-records/` and `ssf/`, it found **3 of 69 documents**; on makit itself it found 132 of 143. Since the sidebar holds many repos, one repo's convention is the wrong default. Deferring to `.gitignore` also **tightens** D2: a gitignored `secrets.md` can no longer be indexed or served, where rev 1 indexed it happily (the dotfile rule never covered it). Dot-directories still drop out via D2, so `.agents/skills/**/SKILL.md` stays out without needing an opt-in — 24 machine-facing files that would have drowned the boards.
| D2 | **Extension allowlist (`.md`, `.html`) plus canonicalise-then-prefix-check** against the worktree root; refuse symlinks that resolve outside it; skip dotfiles and dot-directories; hard-exclude `.git/`, `node_modules/`, `build/`, `.dart_tool/`, `dist/`, `coverage/`; cap at 5 MB. | Serving a worktree is serving secrets: a naive static root hands out `.env` and `.git/config`, which holds tokens. This is the security boundary of the whole feature and it is defined once, in one function. |
| D3 | **`key` is `<worktreePath>:<relPath>` — a snapshot key, never persisted.** The UI re-selects by `(worktreePath, relPath)`. | Same reasoning as `PortDTO.key` (SPEC-41 D6). Files are renamed and moved; a stored key rots silently. Calling it an `id` invites callers to store it. |
| D4 | **The title is extracted, never the filename**: `<title>` for HTML, the first `# H1` for markdown, basename only as a last resort. | `2026-08-07-SPEC-44-ports-forward.md` is unreadable on a 375 pt row. *"SPEC-44 — Ports P4: forward a loopback port to the phone"* is the actual name of the thing, and it is already in the file. This single decision is most of the perceived quality. |
| D5 | **`changed` means "differs from the merge base", not "dirty in the working tree".** | It is the review question — *what did this branch add or touch* — and it reuses the `git diff` already run for the worktree row's `+412/−38` badge. A dirty-tree flag would go green the moment you commit, which is exactly backwards. |
| D6 | **Archived / removed worktrees are excluded entirely.** No orphan badge. | Unlike a port, a removed worktree's files are gone from disk, so the row could only ever be a dead link. Ports needed orphans because a *listener* outlives its worktree; a file does not. |
| D7 | **Markdown is delivered as text over the existing WSS channel** (`docs.read`), capped at 1 MB. HTML is **never** sent over WSS. | A spec file is smaller than the transcript it would sit next to, so it needs no second transport. HTML is only useful when a browser engine renders it, so shipping its bytes to Dart would be pointless. |
| D8 | **In P1, HTML is reachable only by tailnet publish.** No webview until P3. | It is free, it has perfect fidelity (real Safari, real JS, print-to-PDF), and it works on a device that has never paired with makit. It removes the pain in P1 without spending the webview dependency first. |
| D9 | **The published URL is a capability URL: `/docs/<grantId>/<relPath>`**, where `grantId` is 32 bytes of CSPRNG. TTL 30 min, idle-reaped, revocable, and enumerable in one place ("3 docs are currently shared"). Reuse SPEC-44's grant record shape. | **This corrects the mockup**, which drew a plain `/docs/<branch>/<path>` URL. A URL that must open in Safari cannot carry a bearer *header*, so the capability has to be in the path. Publishing is therefore always explicit and always has an off switch. |
| D10 | **rev 2.** The doc listener is a **separate plain-HTTP listener, bound lazily on the first publish** to makit's tailnet address, and **released as soon as the last grant is gone**. Never `0.0.0.0`, never the pinned WSS listener. No `tailscale serve`. | rev 1 said "loopback-only, fronted by `tailscale serve`", which **conflicted with D15's LAN fallback** — a loopback-only listener is unreachable over the LAN, so the fallback was impossible as written. Resolved in favour of the tighter option: tailnet only. Plain HTTP is sufficient because the tailnet already encrypts (WireGuard), and a `ts.net` hostname buys nothing here — **the URL is never typed by a human**, it is tapped, copied, or scanned from a QR — so it would not justify a `tailscale serve` setup/teardown lifecycle. Binding lazily removes rev 1's always-on routable port: makit holds no doc port open for a feature you are not using. |
| D11 | **`docs.snapshot` is a host-only event kind**, added to *both* the `SessionEventKind` `Exclude<>` in `protocol.ts` and `HOST_ONLY_KIND_FLAGS` in `protocol/codec.ts`. `docs.watch {on}` is ref-counted exactly like `ports.watch`. Re-index is driven by `worktree_watcher` with a 400 ms debounce — **no polling.** | Follows `ports.snapshot` precisely: a host-wide snapshot is not a session event and must never be persisted into a session log. `HOST_ONLY_KIND_FLAGS` is typed `Record<Exclude<EventKind, SessionEventKind>, true>`, so the compiler refuses to let the two lists drift — adding the kind in one place fails the build until it is added in the other. **Corrected from rev 0**, which claimed no new event kind was needed; that misread SPEC-44 (which adds none) as if it described SPEC-41 (which introduced `ports.snapshot`). |
| D12 | **The preview is a widget, not a route.** `DocPreview(doc)` must render identically in a bottom sheet (P1), a modal from a chat card (P2), and a split pane (P3). | If P1 builds a route, P3 rewrites P1. This is the single decision that makes the phasing free. |
| D13 | **No thumbnails, and no server-side headless Chrome, in P1 or P2.** | It would add a host binary dependency for decoration. The kind glyph carries the distinction; revisit only if the transcript card measurably reads as bare. |
| D14 | **`docStatus` is parsed opportunistically** from a leading `**Status:** …` line and is **absent rather than guessed.** | This repo writes that line by convention, so it is free signal — but a spec without one must not be labelled. Same discipline as `PortDTO.startedAt`. |
| D15 | **rev 2. Tailnet is the only publishable reach, and failure is stated, never silent.** No tailnet address ⇒ publish refuses with a reason and shares nothing. A failed bind likewise yields no URL. The **LAN fallback is dropped.** | The makit house rule (`serve` in the media skill "refuses to lie"): a publish button that yields an unreachable URL is worse than a disabled one. The LAN fallback is gone because the capability lives in the **URL path** (D9), so on a LAN it would cross the wire in cleartext where anyone sniffing the Wi-Fi could replay it for the grant's lifetime; on the tailnet WireGuard already encrypts it. `reach` stays in the DTO as `"tailnet" \| "lan"` so the wire contract and the app's pills need no change if LAN is ever reinstated behind an explicit opt-in, but P1 only ever emits `tailnet`. |

## Phasing

| Phase | Ships | New deps |
| --- | --- | --- |
| **P1** | The index (`docs.watch` / `docs.list` / `docs.read`), the global **Docs screen** (grouped, filtered, searchable), the **markdown preview widget**, **tailnet publish** for HTML with the grant list and *Stop sharing*, and the worktree-row glyph + desktop popover. | **none** |
| **P2** | **Artifact cards + inline chips** in the transcript (`makit-doc:` scheme, extending the existing media rewriter), and **Quick Open** (⌘⇧O on desktop, pull-to-search on mobile). | none |
| **P3** | `webview_flutter` + the pinned loopback proxy **shared with SPEC-44** → HTML in-app; then **Canvas** (split pane on desktop, second page on mobile) with **live reload** off `worktree_watcher`. | `webview_flutter` |

## What P1 does not do

- No editing. The preview is read-only; makit has an agent for writing.
- No in-app HTML rendering (D8). The HTML row's primary action is *Publish & open*.
- No thumbnails (D13), no full-text search inside documents (titles and paths only), no PDF or
  image files in the index, and no cross-worktree deduplication — the worktree group owns the name.
- No `docs.watch` on mobile background. The watch is released when the screen is popped, exactly
  as `ports.watch` is.

## The index

### What counts as a doc

Resolution order, per worktree:

1. Read `.makit/docs.json` if present (`{ roots?: string[], exclude?: string[] }`); otherwise use
   the defaults in D1.
2. Walk each root, applying D2's exclusions **before** descending (so `node_modules` is never
   entered, not merely filtered).
3. For each surviving file, extract the title (D4), `docStatus` (D14), size, and mtime.
4. Attach `worktreePath`, the owning `sessionId` when the last writer is known, and `changed` (D5).
5. Sort by mtime descending inside each worktree — the doc you want is the one you just made.

### Security properties this must have

`resolveDocPath(worktreeRoot, relPath)` is the only way a path enters the serving layer, and it is
the module the tests hammer hardest:

- rejects absolute paths and any `..` segment after normalisation;
- `realpath`s the result and requires it to be a **path-segment** prefix of the worktree root
  (`/repo-evil` must not match `/repo`);
- rejects a symlink whose target escapes the root;
- rejects any extension outside the allowlist, and any dotfile;
- rejects files over 5 MB;
- is the same function used by both `docs.read` and the static doc route, so the two cannot
  disagree.

### What P1 reuses rather than rebuilds

| Need | Existing thing |
| --- | --- |
| Watch-gated host-wide snapshot + cadence | `server/src/ports/service.ts` |
| Grouped repo → worktree → item screen, filter row | `app/lib/ui/ports/ports_screen.dart` |
| Row layout, detail sheet | `port_token_pill.dart`, `port_detail_sheet.dart` |
| Worktree-row trailing glyph, hover popover | `ports_glyph.dart`, `ports_popover.dart` |
| Markdown rendering + code builder | `app/lib/ui/session/chat_message.dart` |
| Grant record, TTL, idle reaping | SPEC-44 D3 (to be implemented here first) |
| Tree-change notification | `server/src/worktree_watcher.ts` |
| QR rendering | `server/src/pairing/` + the app's pairing screen |
| Merge-base diff | the worktree row's `+412/−38` path in `repo_service.ts` |

## Wire contract

```ts
/** One renderable document inside a worktree. Snapshot identity only (D3). */
export interface DocDTO {
  key: string;                 // "<worktreePath>:<relPath>" — never persisted
  relPath: string;             // "mockups/open-ports.html"
  title: string;              // <title> | first "# H1" | basename (D4)
  kind: "md" | "html";
  bytes: number;
  modifiedAt: number;
  worktreePath: string;
  sessionId?: string;          // last known writer, absent when unknown
  changed?: boolean;           // differs from merge base (D5)
  docStatus?: string;          // "Draft" | "Implemented" | … (D14), absent if unstated
}

export interface DocsSnapshotDTO {
  docs: DocDTO[];
  scanOk: boolean;             // "the walk ran", not "the list is complete" (SPEC-41 D7)
  scannedAt: number;
}

/** An active publication. Same shape discipline as SPEC-44's forward grant (D9). */
export interface DocGrantDTO {
  grantId: string;             // 32 bytes, hex — the capability
  worktreePath: string;
  relPath: string;
  url: string;                 // https://<host>.ts.net/docs/<grantId>/<relPath>
  reach: "tailnet" | "lan";    // never invented — reflects what actually bound (D15)
  expiresAt: number;
}
```

Commands (all app → server, `cmd` frames):

| Kind | Payload | Result |
| --- | --- | --- |
| `docs.watch` | `{ on: boolean }` | ref-counted; first `true` replies with the cached snapshot, then streams `docs.snapshot` (D11) |
| `docs.read` | `{ worktreePath, relPath }` | `{ text }` for `kind === "md"` only; errors for `html` (D7) |
| `docs.publish` | `{ worktreePath, relPath }` | `DocGrantDTO`, or a stated reason (D15) |
| `docs.unpublish` | `{ grantId }` | `{ ok }` |
| `docs.grants` | — | `{ grants: DocGrantDTO[] }` — so the app can say "3 shared" |

## Tests

Server, one file per module, red before green:

- `docs/roots.test.ts` — default roots; `.makit/docs.json` override; malformed config falls back
  rather than throwing.
- `docs/resolve.test.ts` — **the security suite.** `..` traversal, absolute paths, `/repo-evil` vs
  `/repo` prefix confusion, escaping symlink, disallowed extension, dotfile, oversize.
- `docs/title.test.ts` — `<title>`; first `# H1`; H1 that is not the first line; no title →
  basename; `**Status:**` parsed and absent-when-unstated.
- `docs/scan.test.ts` — never descends into excluded dirs; sorts by mtime desc; tolerates an
  unreadable file without failing the walk (`scanOk` semantics).
- `docs/service.test.ts` — watch ref-counting; debounced re-index on watcher fire; no timer when
  unwatched.
- `docs/grants.test.ts` — TTL expiry, idle reap, unpublish, unknown `grantId` rejected.
- `docs/listener.test.ts` — D10 rev 2 lifecycle: nothing binds before the first publish; one bind is reused;
  the port is released at zero grants and re-bound on a later publish; a failed bind yields `null`, not a URL;
  no tailnet address binds nothing at all.
- `docs/route.test.ts` — capability URL serves the file; wrong/expired `grantId` → 404 (not 403 —
  do not confirm existence); traversal attempt → 404; correct `Content-Type`; `HEAD` supported;
  **and every unmatched path is answered rather than left hanging** (the dedicated listener has no
  other handler, so `/favicon.ico` — which Safari requests on every visit — would otherwise hold a
  socket until Node's 60 s headers timeout).
- `docs/publish.test.ts` — refuses before probing reachability; mints nothing when there is no reach;
  **percent-encodes each URL segment** (a doc containing `#` or `?` would otherwise truncate the path
  and 404 against its own grant).
- `contract.test.ts` — `DocsSnapshotDTO` in `snapshots.json`, **not** `events.json` (that file
  asserts one entry per *session* kind and feeds each to `decodeSessionEvent`), plus a guard that
  `docs.snapshot` is rejected by `decodeSessionEvent` and accepted by `decodeFrame`.

App:

- `store/docs_test.dart` — tolerant parse: absent `changed`/`docStatus`/`sessionId`.
- `ui/docs/docs_screen_test.dart` — grouping, filter counts, empty state, search.
- `ui/docs/doc_preview_test.dart` — markdown renders; front-matter becomes chips; internal links
  resolve in-preview, external links go to `url_launcher`.
- `ui/docs/publish_test.dart` — publish shows the URL + QR; *Stop sharing* revokes; the
  degrade-loudly path (D15) shows a reason, not a dead URL.

Every new test's bite is proven by reverting only the production line and watching it fail.

## Verification (beyond unit tests)

1. `cd server && node_modules/.bin/tsc -p . --noEmit` clean; `npm test` all-green with the
   pre-existing count preserved.
2. `cd app && flutter analyze --fatal-infos --no-pub` reports no issues; `flutter test --no-pub`
   all-green against the known-flaky baseline (compare counts, and `grep -v ": loading "` must be
   empty).
3. A real-machine probe: index this very worktree and compare the count against
   `find mockups docs -name '*.md' -o -name '*.html'` by eye. Expect 27 boards and 70 specs.
4. Publish `mockups/open-ports.html`, then `curl -sI` the tailnet URL for `200`, `curl` a wrong
   `grantId` for `404`, and open the real URL on the phone. Then *Stop sharing* and `curl` again
   for `404`.
5. `docs.read` a spec on the phone and confirm the front-matter chips and code blocks render.
