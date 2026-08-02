# SPEC-33 — User attachments (picker + clipboard paste)

**Status:** implemented (phase 1: images, file hand-off, picker + paste) · **Date:** 2026-08-01 · **Depends on:** SPEC-22 (assistant
display media — store, route, pinned client, renderer), SPEC-26 (unified
composer), SPEC-29 (adapter capability negotiation) · **Blocks:** —

> SPEC-22 explicitly deferred this: *"Not built: … user→agent uploads (pi
> advertises `promptCapabilities.image: true`, so the input side is available
> for a follow-up spec)."* This is that spec — the **input** half of makit's
> media story.

---

## 1 · Problem

The user cannot send the agent an image. Not from the gallery, not from the
camera, not from the clipboard — and the affordance is already on screen,
disabled:

```dart
// app/lib/ui/composer/composer.dart:_buildPlus()
return const IconButton(
  icon: Icon(PhosphorIconsLight.paperclip),
  tooltip: 'Attachments coming in v2',
  onPressed: null,          // ← disabled since SPEC-06
);
```

This is the single most common thing a person wants to do from a phone while an
agent works on their machine: screenshot the broken UI, the Xcode error, the
Figma frame, the failing dashboard — and hand it over. Today the only path is
"describe it in prose", or side-load the file onto the desktop by hand and tell
the agent a path. Both are worse than the thing they replace.

The wire is text-only end to end, in four places:

| Layer | Site | Shape today |
|---|---|---|
| App → server cmd | `app/lib/store/store.dart:434` `sendMessage` | `{kind:'send.message', sessionId, text}` |
| Server cmd handler | `server/src/ws/commands/session.ts:36` | `if (typeof text !== "string") → BadRequest`; nothing else read |
| Session → adapter | `server/src/session.ts:451` | `await this.adapter.send({ text })` |
| Adapter contract | `server/src/adapters/adapter.ts:72` | `interface UserInput { text: string }` |
| ACP prompt | `server/src/adapters/acp.ts:254` | `prompt: [{ type: "text", text: input.text }]` |
| codex prompt | `server/src/adapters/codex.ts:197` | `input: [{ type: "text", text, text_elements: [] }]` |

And on the client, Flutter's `Clipboard.getData` **only reads text** — there is
no first-party API for reading an image off the pasteboard, so ⌘V of a
screenshot is not a wiring problem, it is a missing platform channel.

## 2 · What already exists (do not rebuild)

SPEC-22 built the hard, security-sensitive half of this feature for the
*outbound* direction, and every piece is reusable as-is:

| Piece | File | Reuse |
|---|---|---|
| Content-addressed blob store, sha256 ids, mime allowlist, 24 MB cap, atomic temp→fsync→rename publish, idempotent `put` | `server/src/media/store.ts` | **as-is** — uploads are just another producer |
| Authenticated media route (`GET`/`HEAD /media/<sha256>`, device bearer, `trustLoopback`, ranges, `immutable` caching) | `server/src/media/route.ts` | **extend** with `POST` |
| Descriptor type carried in events instead of bytes | `MediaDescriptor` | **as-is** |
| TLS-pinned `HttpClient` + media fetch/cache | `app/lib/transport/pinned_http.dart`, `media_client.dart` | **extend** with an upload call |
| Inline thumbnail → fullscreen renderer | `app/lib/ui/session/media_view.dart` | **as-is** for the user's own bubbles |
| 32 MB child-RPC frame cap (base64 payloads fit) | `server/src/adapters/child_transport.ts` | already raised by SPEC-22 |

The remaining work is a **transport verb, a wire field, two prompt builders, and
composer UI**. The blast radius is smaller than SPEC-22's.

## 3 · Design decisions

### 3.1 Upload over HTTP `POST /media`, not base64 on the WebSocket

| | A. base64 in `send.message` | **B. `POST /media` then send the id (chosen)** |
|---|---|---|
| WS hot path | a 6 MB screenshot → ~8 MB text frame on the same socket that carries live token streams; head-of-line blocks the transcript | untouched |
| Event log | must be stripped out server-side anyway before `user.message` is persisted (the log is replayed in full on resume — ARCHITECTURE §2.2), so the base64 is *pure overhead* | descriptor only, by construction |
| Progress / cancel / retry | none — one atomic frame | per-request, cheap |
| Dedupe | none | content hash: re-sending the same screenshot is a no-op upload |
| Auth surface | existing WS handshake | existing bearer header, same `DeviceRegistry`, same pinned client |
| New code | frame-size plumbing | one `POST` branch in a route that already exists |

Chosen: **B**. Note that the media route's auth model is the reason B is nearly
free — `authorized()` in `route.ts` is verb-agnostic.

`POST /media` contract:

```
POST /media
Authorization: Bearer <deviceBearer>          # or loopback + trustLoopback
Content-Type: image/png                       # must be in MEDIA_MIME_ALLOWLIST
Content-Length: <n>                           # required; > maxBlobBytes → 413
<raw bytes — no multipart>

201 {"mediaId":"<sha256>","mime":"image/png","sizeBytes":12345}
```

- Raw body, **not** multipart: one file per request, no boundary parser to
  harden, and the client already knows the mime.
- `Content-Length` is mandatory and pre-checked, and the accumulated body is
  checked again per chunk — a lying/chunked sender is aborted before it can
  balloon the daemon (same "cap before allocating" rule as `putBase64`).
- Idempotent: identical bytes ⇒ same `mediaId`, `201` either way.
- Filenames are **not** stored server-side (no path, no user-controlled string
  on disk). The display name rides on the `send.message` command instead — see
  §3.3 — and is sanitised only where a file must be materialised (§3.4).

### 3.2 Rejected: uploading into the worktree directly from the app

No new file-write verb on the wire. Bytes land in the content-addressed store,
and only the server decides if/where a file is materialised (§3.4). This keeps
"the app can never name a path on the host" true, which is the property that
makes the media route safe today.

### 3.3 `send.message` grows an optional `attachments[]`

```ts
// protocol.ts
export interface WireAttachment {
  mediaId: string;      // sha256 hex; must already exist in the store
  name?: string;        // display + materialised filename hint, sanitised
}
// cmd: { kind:"send.message", sessionId, text, attachments?: WireAttachment[] }
```

Server-side validation in `commands/session.ts` (mirroring `parseConfigPicks`'s
"malformed entries are dropped" style, with one deliberate exception):

- non-array / non-object entries / bad id shape → **dropped**;
- a well-formed id that `store.stat()` cannot resolve → **`BadRequest`**, not
  dropped. An expired/GC'd upload must not silently turn a "look at this
  screenshot" turn into a bare text prompt; the user has to know.
- caps: `MAX_ATTACHMENTS = 8` per message, and a total-bytes cap; over → `BadRequest`.
- `text` may now be **empty** when `attachments.length > 0` (an image alone is a
  valid turn). It stays required-as-a-string.

`UserInput` becomes `{ text: string; attachments?: MediaAttachment[] }` where
`MediaAttachment = MediaDescriptor & { name?: string }`, and
`Session.sendUserMessage(text, attachments?)` forwards it. Every existing
adapter compiles unchanged (optional field, ignored).

### 3.4 Delivery to the agent: file hand-off first, inline images later

Two mechanisms exist. **The general one ships first**; the better one is a
follow-up phase, gated on a capability we have not yet verified (§7 O3).

**(a) Materialised file + path in the prompt — the v1 default, for every adapter:**

```
<user text>

Attached files:
- /path/to/worktree/.makit/attachments/3f2a1b-screenshot.png
```

- Written under `<agent cwd>/.makit/attachments/` — the session's worktree when
  it has one, otherwise the repo root it was started in. (Do **not** gate on a
  recorded `worktreePath`: the default session legitimately has none.) Filename
  `<mediaId[0..6]>-<sanitised name or "attachment.png">` — the hash prefix
  guarantees uniqueness without trusting the client's name; sanitisation strips
  everything outside `[A-Za-z0-9._-]` and rejects `..`.
- Kept out of git via **`$GIT_DIR/info/exclude`**, not a committed
  `.gitignore`: makit must not create a diff in the user's worktree just because
  they pasted a screenshot.
- Works on **every** agent and every backend, with zero capability negotiation
  and no size ceiling beyond the store's own cap. That generality is why it goes
  first. The cost: the agent must *choose* to open the file — usually it does,
  and the prompt suffix names it explicitly, but it is one step removed from
  "here, look at this". The UI is honest about that (§3.5).

**(b) Inline image content block — later phase.** For ACP agents advertising
`agentCapabilities.promptCapabilities.image === true`:

```ts
prompt: [
  ...attachments.map(a => ({ type: "image", data: <base64>, mimeType: a.mime })),
  { type: "text", text: input.text },
]
```

Images first, text last: the text usually *refers* to the image ("why is this
button misaligned?"), and models weight a trailing instruction over a leading
one. Two constraints on this path:

- Base64 inflates by 4/3, so the store's 24 MB blob becomes a 32 MB child-RPC
  frame — exactly the cap. The inline path therefore takes its own lower ceiling
  (`MAX_INLINE_ATTACHMENT_BYTES = 8 MB`, ~10.7 MB encoded) and **falls back to
  (a)** above it. (a) is the floor under everything.
- Capability is per **agent**, but image support is really per **model** (an ACP
  agent may advertise `image: true` while the user's currently selected model
  cannot see pictures). SPEC-26/31 already model per-active-model config, so the
  gate is `promptImage && <active model claims image support>` — and any
  uncertainty resolves to (a), never to a dropped image.

Mechanically: phase (b) negotiates the capability where it is *used* — in the
send path — and records the resulting per-blob decision on the `user.message`
event (see §3.5). **v1 plumbs no capability at all.** An earlier cut did: a
`PromptCapabilities` interface on `AgentAdapter`, derived from ACP `initialize`,
surfaced as `promptImage` on the session snapshot, whose only consumer was the
hand-off note. It was removed in review because the note it drove was wrong in
three ways at once — see §3.5. The paperclip is enabled whenever there is a
server to upload to — the file form needs nothing else, since every live session
has a cwd.

### 3.5 `user.message` carries descriptors, and the app renders them

```ts
{ kind: "user.message", payload: { text, attachments?: [{ mediaId, mime, sizeBytes, name? }] } }
// As shipped, the app parses `{mediaId, mime, name?}` into `MediaAttachmentRef`
// and ignores `sizeBytes`: nothing renders it. The app's own optimistic copy is
// built by `MediaAttachmentRef.toEchoWire()`, and the outbound `send.message`
// form by `toWire()` (id + name only) — one class, two wire shapes, so the
// build-then-reparse cannot drift.
```

Descriptors only — the same reason SPEC-22 gives (replayed log). The app's
existing `MediaView`/`MediaClient` renders the user's own thumbnails from
`GET /media/<id>`, so a resumed session shows what was sent. Both adapters must
include `attachments` in the echo they already emit (`acp.ts:250`,
`codex.ts:191`), and `Store.appendOptimisticMessage` must include them too or
the optimistic bubble and the echo will render differently for one frame
(`store.dart:399` — the seq-collision dedup means the *optimistic* copy is the
one that survives, so a bubble without attachments would be permanent).

**The hand-off note.** When an attachment is delivered as a file rather than
shown to the model directly (§3.4a), the user's own bubble carries a small muted
caption under the thumbnails — e.g. *"Sent as a file for the agent to open"* —
so a lukewarm reply ("I see a path…") is explicable instead of mysterious.

**As shipped: the note is unconditional.** makit always delivers a file, so the
note is true of every attachment-bearing turn, and nothing gates it.

The first cut gated it on a session-level `promptImage` capability, for a real
reason: the seq-collision dedup above means the optimistic bubble is the copy
that survives, and the app cannot know the server's per-blob decision at that
instant, so deriving from a snapshot field kept optimistic and replayed renders
identical. That reasoning is sound about *rendering* and wrong about *meaning*.
Review found three defects:

1. **Wrong polarity.** The flag says what the agent *could* accept; the note
   states what makit *did*. Since v1 always writes a file, an agent advertising
   `image: true` suppressed a true statement — the better the agent, the less the
   user was told, with no explanation on screen when the agent ignored the image.
2. **Wrong granularity.** ACP negotiates `promptCapabilities` once per *agent
   process*, at `initialize`, before any model is chosen. Image support is a
   property of the **model**, which the user can change mid-session
   (`session.action('model', …)` — same connection, capability never re-read). The
   flag was stale by design. This is O4's question, arriving early.
3. **Wrong lifetime.** `promptImage` is a *live session* field, applied by the app
   to every bubble in the transcript. A message's delivery is a fact frozen at
   send time. Once (b) makes delivery conditional, switching to an inline-capable
   model would silently strip the note from older messages that really were files
   — a transcript that rewrites its own history.

**Phase (b) therefore records delivery on the event, not on the session:**
`payload.deliveredAs: "file" | "inline"`, written by `prepareTurn` in
`media/attach.ts`, which is the one place that knows what it actually did. That
survives model switches, replays correctly, and lets one transcript hold both
kinds of turn side by side.

The optimistic-render problem the first cut was avoiding remains, and (b) must
answer it: the app cannot predict a per-blob fallback (an over-8 MB image on an
image-capable agent still goes as a file). The likely answer is a targeted merge
— let the server's echo update the optimistic bubble's `deliveredAs` even though
the dedup drops the rest of the payload — rather than a session-level guess.
Deciding that is part of (b), not of v1.

### 3.6 Images only in this spec

`MEDIA_MIME_ALLOWLIST` (png/jpeg/gif/webp/bmp) is **not widened**. PDFs, logs
and CSVs are a different feature: they need a non-image render path, a
`Content-Disposition` policy on the route, and they only ever work through the
path form (b). Deferred to a later phase (§6) rather than half-built here.

## 4 · Client (app) design

### 4.1 Attachment state lives in the composer's caller, not the composer

`Composer` is already a controlled widget (`controller`, `initialText`,
`onDraftChanged`, `footerActions`). Attachments follow the same shape: a
`List<ComposerAttachment>` + `onAttachmentsChanged` in, `onSend(text,
attachments)` out. The upload lifecycle (pending → uploaded → failed) is owned
by a small notifier alongside `composerDraftsProvider`, so a desktop pane switch
does not lose an in-flight upload.

> **As shipped:** the composer takes one nullable value object,
> `ComposerAttachmentsApi? attachments` (staged list + pick/remove/retry/clipboard
> read/paste-stage), built per surface by `composerAttachments(context, ref,
> sessionId)`. Null means "not attachment-aware" (the free-text answer composers);
> a null `pick` inside means "nowhere to upload right now", which is the single
> gate for the inert paperclip and for leaving ⌘V to the field. The first cut used
> six independent optional callbacks and both surfaces then re-tested
> `canAttachHere` four times each — the duplication the object removes.

### 4.2 Three entry points

| Entry | Platform | Plugin |
|---|---|---|
| Paperclip → *Photo library* / *Take photo* | iOS/Android | `image_picker` (publisher **flutter.dev**) |
| Paperclip → *Choose file…* | macOS desktop | `file_selector` (publisher **flutter.dev**) |
| ⌘V / long-press *Paste* with an image on the pasteboard | **all platforms** | `super_clipboard` (see §4.3) |

`image_picker` and `file_selector` are both flutter.dev-published, which keeps
`SECURITY.md`'s native-plugin policy satisfiable (exact pin + `tool/audit.sh`
re-run on bump).

### 4.3 Clipboard images: `super_clipboard`, pinned

`Clipboard.getData` handles `text/plain` only, so pasting a screenshot needs
native code. **Decision: take the library** (`super_clipboard`) rather than
hand-rolling a MethodChannel — paste then works on Android, Windows and Linux
too, and drag-and-drop later comes from its sibling package instead of a second
hand-rolled surface.

Vetted against `app/SECURITY.md` §1 ("To add a new package") on 2026-08-01:

| §1 criterion | `super_clipboard` 0.9.1 |
|---|---|
| Verified publisher | ✅ `nativeshell.dev` (Matej Knopp — also `irondash`, widely used in the Flutter ecosystem) |
| ≥130 pub points | ✅ 160 |
| License | ✅ MIT |
| Recent publish | ⚠️ last release 2025-06-11 (~13 months). Stable, not abandoned — but note it |
| Native code → security review | ⚠️ **yes** — Rust, via transitive `super_native_extensions` 0.9.1 |
| ≥3 days old (`tool/pub_cooldown.dart` §8) | ✅ comfortably |
| Self-described maturity | ⚠️ README still says "early stages of development and quite experimental" |

**Pin exactly** — `super_clipboard: 0.9.1` — per the pubspec's native-plugin
rule, not `^`. Also pin the transitive `super_native_extensions` if the lockfile
lets it float.

**The one real policy conflict, and its fix.** Quoting the package: *"If you
don't have Rust installed, the plugin will automatically download precompiled
binaries for target platform."* That is a build-time binary fetch outside
`pubspec.lock`'s hash coverage — exactly the class of thing `SECURITY.md` §3/§4
exist to prevent. Mitigation, which must land with the dependency:

1. **Require `rustup`** on dev machines and in CI. The build detects its presence
   and compiles from source, so no prebuilt binary is ever downloaded.
2. Add a `tool/audit.sh` step that fails when `super_clipboard` is present and
   `rustup` is not — the check has to be mechanical or it will rot.
3. Document it in `docs/DEVELOPMENT.md` next to the existing toolchain notes.

Two smaller Android notes: the `DataProvider` entry in `AndroidManifest.xml` is
only needed to **write** images to the clipboard — makit only reads, so it is
omitted; and the NDK (~1 GB, auto-installed on first build) plus `minSdk ≥ 23`
become hard requirements (`app/android/app/build.gradle.kts` currently inherits
`flutter.minSdkVersion`, which satisfies this — verify, don't assume).

Usage is format-negotiated, which suits us: read `Formats.png` when
`reader.canProvide(...)`, and let the library transparently convert macOS TIFF /
Windows DIB into PNG — one code path instead of three.

**Landing notes — measured when the dependency actually went in (2026-08-01, T7).**
Two consequences the table above does not predict:

1. **CocoaPods is back.** `super_native_extensions` does not support Swift
   Package Manager, so `flutter build` re-introduced CocoaPods into two
   previously SPM-only Xcode projects: new committed `ios/Podfile{,.lock}` +
   `macos/Podfile{,.lock}`, Pods groups/frameworks/script phases in both
   `Runner.xcodeproj/project.pbxproj`, and a `#include?` of the generated Pods
   xcconfig in each `Flutter-*.xcconfig`. CI now needs CocoaPods. Flutter also
   warns that non-SPM plugins *"will become an error in a future version of
   Flutter"* — a standing deprecation risk on this dependency.
2. **Two Windows-only transitives were downgraded** by the resolver:
   `win32` 6.3.0 → 5.15.0 and `flutter_secure_storage_windows` 4.2.2 → 4.1.0.
   makit does not ship Windows, and `osv-scanner` reports no advisories against
   either version, so this is recorded rather than acted on — but it *is* a
   downgrade of the package that would hold the bearer on a platform we may
   target later.

Cost, for the record: 29 lockfile changes and ~600 compiled crates to read one
PNG off the pasteboard. Verified green: macOS debug build, 1106 tests, full
`tool/audit.sh` (including the new rustup gate, checked in both directions).

Paste interception: the composer's field already routes keys through
`Shortcuts`/`Actions` (`_shortcuts()`), so ⌘V maps to a `PasteIntent` handler
that asks the clipboard for an image first and **falls through to the default
paste action** when there is none. Never swallow a text paste.

### 4.4 Composer visuals

A chip strip above the field (only when non-empty): thumbnail + name + size,
`✕` to remove, a progress ring while uploading, red border + tap-to-retry on
failure. Send is enabled when `text.isNotEmpty || attachments.any(uploaded)`,
and blocked while any upload is in flight (so an id is never sent before the
bytes exist).

## 5 · Security notes

1. **No new auth model.** `POST /media` reuses `authorized()` — same bearer,
   same `DeviceRegistry`, same loopback rule as the `GET`.
2. **No client-named paths, ever.** Filenames are hints; the server derives the
   on-disk name from the content hash and sanitises the rest (§3.4).
3. **Cap before allocating** on both the route (`Content-Length` + per-chunk)
   and the inline base64 path (§3.4a).
4. **Allowlist unchanged**, so SVG/HTML can still never be stored or served.
5. **Containment**: materialised files go under the agent's own cwd (its worktree,
   or the repo root for the default session) and nowhere else. A cwd that cannot
   be written fails loudly — `session.error`, turn not sent — rather than
   degrading silently.
6. **Never log bytes, names, or ids at info level** — `send.message` logging is
   already metadata-only (`session.ts:47`); keep it that way (log
   `attachments=<count>`).
7. **Never log an attachment's id, name, or bytes** — only counts (`attachments=<n>`).

## 6 · Out of scope (later phases)

- **Inline image content blocks (§3.4b)** — the quality upgrade over the file
  hand-off. Deliberately a follow-up: it needs O3 verified, a per-model gate
  (not just per-agent), and the 8 MB fallback rule. v1 ships the general path.
- Non-image files (PDF/CSV/log) — needs allowlist split + non-image rendering.
- Desktop drag & drop onto the composer (cheap once `super_clipboard`'s sibling
  `super_drag_and_drop` is on the same pinned Rust base — but still later).
- Video/audio attachments (SPEC-22 phase 4 is still unbuilt on the output side).
- Media GC/refcounting — inherited SPEC-22 debt, now with a second producer;
  worth its own spec.
- Probing whether codex's `app-server` accepts image input elements (its
  `input[]` is typed `{type:"text", text, text_elements}`; an image element type
  is unverified). Until then codex takes the path form.

## 7 · Open questions

- ~~**O1**~~ — **decided 2026-08-01:** take `super_clipboard`, exact-pinned at
  the latest release that clears `SECURITY.md` §1 (0.9.1), with the `rustup`
  requirement + audit check that closes its prebuilt-binary hole (§4.3).
- ~~**O2**~~ — **decided:** Android is included, via the same library.
- **O3** — Confirm `agentCapabilities.promptCapabilities.image` is the exact
  path in the installed `@agentclientprotocol/sdk` ^1.3.0 schema, and that
  pi-acp sets it. Cheap: assert against a live `initialize` response in
  `server/test`. **Does not block v1**, which uses the file form and no longer
  reads the capability at all (§3.5); it gates the inline phase only. Note O4
  turns out to be the harder half: the ACP path can be exactly right and still be
  the wrong question, because it answers per agent process, not per model.
- **O4** (new, from the §3.4b deferral) — where does "this *model* can see
  images" come from? SPEC-31 gives us per-active-model config, but no model
  advertises image support today. Likely a small static table keyed by model id,
  which is a maintenance burden worth naming now rather than discovering later.

## 8 · Acceptance

1. From the phone, paperclip → gallery → pick a screenshot → send with no text →
   the agent (pi **or** codex) is handed
   `<worktree>/.makit/attachments/<hash>-<name>.png`, opens it, and describes it.
2. `git status` in that worktree stays clean afterwards.
3. The sent bubble shows the thumbnail plus the muted *"sent as a file"* note,
   and looks **identical** after a server restart + session resume (descriptors
   survive the replayed log; optimistic and replayed renders agree).
4. ⌘V a screenshot into the desktop composer → chip appears → send works.
   Long-press → Paste does the same on the phone. ⌘V of *text* still pastes text.
5. Uploading the same image twice performs one store write (same `mediaId`).
6. A 30 MB image is rejected client-side with a readable message; a lying
   `Content-Length` is aborted server-side.
7. `app/tool/audit.sh` passes, and **fails** when `rustup` is absent (§4.3).

Later phase (§3.4b): the same flow on an image-capable agent puts the picture
directly in the conversation and the note disappears.
