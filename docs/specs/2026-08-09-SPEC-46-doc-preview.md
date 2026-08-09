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
| D1 | **An allowlist of doc roots, not a file tree.** Defaults: `mockups/`, `docs/`, and `*.md` at the repo root. `.agents/skills/**/SKILL.md` is **opt-in** via `.makit/docs.json`. | A tree invites traversal, needs lazy loading, and buries the four directories you want behind twelve you do not. 22 machine-facing skill files would drown the 27 boards a human actually opens. |
| D2 | **Extension allowlist (`.md`, `.html`) plus canonicalise-then-prefix-check** against the worktree root; refuse symlinks that resolve outside it; skip dotfiles and dot-directories; hard-exclude `.git/`, `node_modules/`, `build/`, `.dart_tool/`, `dist/`, `coverage/`; cap at 5 MB. | Serving a worktree is serving secrets: a naive static root hands out `.env` and `.git/config`, which holds tokens. This is the security boundary of the whole feature and it is defined once, in one function. |
| D3 | **`key` is `<worktreePath>:<relPath>` — a snapshot key, never persisted.** The UI re-selects by `(worktreePath, relPath)`. | Same reasoning as `PortDTO.key` (SPEC-41 D6). Files are renamed and moved; a stored key rots silently. Calling it an `id` invites callers to store it. |
| D4 | **The title is extracted, never the filename**: `<title>` for HTML, the first `# H1` for markdown, basename only as a last resort. | `2026-08-07-SPEC-44-ports-forward.md` is unreadable on a 375 pt row. *"SPEC-44 — Ports P4: forward a loopback port to the phone"* is the actual name of the thing, and it is already in the file. This single decision is most of the perceived quality. |
| D5 | **`changed` means "differs from the merge base", not "dirty in the working tree".** | It is the review question — *what did this branch add or touch* — and it reuses the `git diff` already run for the worktree row's `+412/−38` badge. A dirty-tree flag would go green the moment you commit, which is exactly backwards. |
| D6 | **Archived / removed worktrees are excluded entirely.** No orphan badge. | Unlike a port, a removed worktree's files are gone from disk, so the row could only ever be a dead link. Ports needed orphans because a *listener* outlives its worktree; a file does not. |
| D7 | **Markdown is delivered as text over the existing WSS channel** (`docs.read`), capped at 1 MB. HTML is **never** sent over WSS. | A spec file is smaller than the transcript it would sit next to, so it needs no second transport. HTML is only useful when a browser engine renders it, so shipping its bytes to Dart would be pointless. |
| D8 | **In P1, HTML is reachable only by tailnet publish.** No webview until P3. | It is free, it has perfect fidelity (real Safari, real JS, print-to-PDF), and it works on a device that has never paired with makit. It removes the pain in P1 without spending the webview dependency first. |
| D9 | **The published URL is a capability URL: `/docs/<grantId>/<relPath>`**, where `grantId` is 32 bytes of CSPRNG. TTL 30 min, idle-reaped, revocable, and enumerable in one place ("3 docs are currently shared"). Reuse SPEC-44's grant record shape. | **This corrects the mockup**, which drew a plain `/docs/<branch>/<path>` URL. A URL that must open in Safari cannot carry a bearer *header*, so the capability has to be in the path. Publishing is therefore always explicit and always has an off switch. |
| D10 | **The doc listener is a separate plain-HTTP listener bound to `127.0.0.1` only**, fronted by `tailscale serve`. It is never bound to `0.0.0.0` and never shares the pinned WSS listener. | `tailscale serve` terminates real TLS with a real cert on a stable hostname, which is the whole point of D8 — no port to remember, no cert wall. Keeping it off the pinned listener means a bug in static file serving cannot touch the authenticated control plane. |
| D11 | **No new event kind.** `docs.watch {on}` is ref-counted exactly like `ports.watch`; snapshots stream on the existing channel. Re-index is driven by `worktree_watcher` with a 400 ms debounce — **no polling.** | SPEC-41 D8's reasoning: a host-wide snapshot is not a session event, and adding a kind means touching both the `Exclude<>` in `protocol.ts` and `HOST_ONLY_KINDS` in `protocol/codec.ts` for no gain. |
| D12 | **The preview is a widget, not a route.** `DocPreview(doc)` must render identically in a bottom sheet (P1), a modal from a chat card (P2), and a split pane (P3). | If P1 builds a route, P3 rewrites P1. This is the single decision that makes the phasing free. |
| D13 | **No thumbnails, and no server-side headless Chrome, in P1 or P2.** | It would add a host binary dependency for decoration. The kind glyph carries the distinction; revisit only if the transcript card measurably reads as bare. |
| D14 | **`docStatus` is parsed opportunistically** from a leading `**Status:** …` line and is **absent rather than guessed.** | This repo writes that line by convention, so it is free signal — but a spec without one must not be labelled. Same discipline as `PortDTO.startedAt`. |
| D15 | **Degrade loudly, never silently.** If `tailscale serve` is unavailable, publish offers a LAN URL explicitly labelled `lan`; if there is no usable address at all, the action reports why and does nothing. | The makit house rule (`serve` in the media skill "refuses to lie"). A publish button that yields an unreachable URL is worse than a disabled one. |

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
| `docs.watch` | `{ on: boolean }` | ref-counted; first `true` replies with the cached snapshot, then streams (D11) |
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
- `docs/route.test.ts` — capability URL serves the file; wrong/expired `grantId` → 404 (not 403 —
  do not confirm existence); traversal attempt → 404; correct `Content-Type`; `HEAD` supported.
- `contract.test.ts` — `DocsSnapshotDTO` in `snapshots.json`, **not** `events.json` (that file
  asserts one entry per *session* kind).

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
