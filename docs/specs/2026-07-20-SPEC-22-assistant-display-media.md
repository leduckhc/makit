# SPEC-22 — Assistant display media (images, video, gifs)

**Status:** proposed · **Depends on:** SPEC-15 (adapter consolidation), SPEC-16
(app chat), ACP transition · **Blocks:** —

## Goal

Let the assistant show **visual content** in the chat — images, GIFs, and video
— instead of only text/markdown and tool-output text. The phone renders inline
thumbnails that open fullscreen; large media streams instead of being inlined
into the event log.

## Why

Coding agents already produce and touch visual artifacts: the `read` tool reads
a PNG and returns it as an image block, and MCP tools return images/charts.
Today those tool-result and content-block images are **dropped or flattened to
text** before they reach the phone. (Markdown image URLs in prose are a separate
case — they already render, but insecurely; see the source table.) Surfacing
agent-produced media is a large, visible UX win. The blast radius is real but
bounded: a new event kind (four registration points), a media store + dual-
listener HTTP route with token auth, a shared pinned HTTP client, and a
renderer.

## Where media actually comes from (verified against the code)

This is the key finding that shapes the design — the assistant does **not**
stream image content blocks in its prose:

| Source | Path | Today | Notes |
| --- | --- | --- | --- |
| **Tool results** (`read` a PNG, MCP image tools) | pi native | `extractResultText()` (`server/src/adapters/pi.ts:676`) keeps only `c.text`, **drops `{type:"image",data,mimeType}`** | pi's own `ImageContent` = `{type:"image", data:<base64>, mimeType}`. This is the primary source on the pi path. |
| **Agent message / tool content blocks** | ACP | `contentBlockText()` (`server/src/adapters/acp-map.ts:201`) returns `""` for non-`text` blocks | ACP reuses MCP `ContentBlock`: `image`, `audio`, `resource` (blob), `resource_link`. |
| **Markdown image URLs** in prose (`![](https://…)`) | both | `flutter_markdown_plus` **already renders** these via its default `Image.network` builder (no `imageBuilder` needed) | So this "works" today but is **insecure/unmanaged**: no TLS pinning, no size/scheme policy, no caching. It needs a *loader/policy* pass, not enablement. |
| **Video / GIF bytes** | neither | — | Agents do not *generate* video. Video/GIF realistically arrives only as a **referenced file** (`file://…` / `resource_link`) or a URL. |

**Consequence:** pi's assistant message stream (`message_update` →
`text_*`/`thinking_*`) is text-only; do **not** look for images there. Surface
media from **tool results** (pi) and **content blocks** (ACP), plus markdown
URLs.

## Design decision — reference + serve, not inline base64

Events are written to SQLite and are **authoritative**: the whole log is
replayed on reconnect (`docs/ARCHITECTURE.md §2.2`). Keeping large blobs out of
the event log is the primary driver (the log is replayed in full on every
resume). The 4 MB agent↔server frame cap (`child_transport.ts:32`) is a
secondary point — it only bounds *child RPC* frames, not the phone WS — but it
does mean blob ingestion **must cap decoded size before allocating/writing**
(decompression-bomb guard).

| | A. Inline base64 in the event | **B. Reference + HTTP serve (chosen)** |
| --- | --- | --- |
| SQLite log | bloats; a 10 MB clip re-sent every resume | tiny descriptor; bytes stored once |
| Video/GIF | no seeking | HTTP **range requests** → stream/seek |
| Caching | none | app caches by content hash |

Chosen: **content-addressed media store on disk + an authenticated HTTPS media
route**; events carry a small descriptor. This is the standard chat-app model
(Slack/Signal/Matrix).

### TLS pinning is NOT free for the media route (critical)

The phone pins the server's self-signed cert **only inside the WS client's
custom `HttpClient`** (`app/lib/transport/ws_client.dart` — DER-sha256
fingerprint check). `Image.network`, `cached_network_image`, and
`video_player`/native players use their **own** HTTP stacks and will **reject
the self-signed cert** → every media fetch fails. Therefore this spec requires a
**shared pinned HTTP client** (the same fingerprint-verification callback the WS
client uses, extracted into a reusable `HttpClient`) that the image, GIF, and
thumbnail loaders are wired to. This is a prerequisite of phase 1, not an
afterthought.

**Video is a special case — a Dart `HttpClient` does not reach it.**
`video_player` delegates the network fetch to the native platform player
(AVFoundation on iOS/macOS, ExoPlayer on Android). It exposes only
`httpHeaders` on `VideoPlayerController.networkUrl`; it does **not** accept a
custom Dart `HttpClient`, so the shared pinned client cannot verify the cert
for video playback. Passing the capability token via `httpHeaders` still leaves
the self-signed cert to be validated by the native stack, which rejects it.
Phase 4 must therefore pick one of:
- **Prefetch-to-file (preferred, no native work):** download the media through
  the shared pinned `HttpClient` into a local temp file, then play the
  `file://` URI (`VideoPlayerController.file`). Reuses the phase-1 pinning path
  and range support; costs local disk + a first-byte delay.
- **Platform-side pinning:** configure certificate pinning natively
  (`NSAppTransportSecurity` / a custom `AVAssetResourceLoaderDelegate` on Apple,
  a pinning `OkHttp`/`TrustManager` on Android). More native surface, per-
  platform, and easy to get wrong — only if streaming/seek without a full
  prefetch is required.
Do not rely on request headers alone for video TLS.

## Scope

### In

**Server**
- **Media store** `~/.makit/media/<sha256>` (content-addressed → free dedupe +
  immutable caching). Metadata sidecar or SQLite row: `{mime, bytes, width,
  height, durationMs?}`. Size-capped LRU GC.
- **Durable-before-event write ordering** (applies to both the pi adapter and
  the ACP mapper). Events are authoritative and replayed, so a committed
  `agent.media` must never outlive its blob. Ingestion order is strict:
  1. write bytes to a temp file in the media dir, `fsync` the file, `rename`
     into `~/.makit/media/<sha256>` (atomic same-filesystem publish), then
     `fsync` the directory;
  2. commit the metadata row/sidecar;
  3. only then append the `agent.media` event.
  If the event append fails after the blob is written, **clean up the orphaned
  blob + metadata** (a dedup refcount, if the sha256 is already referenced,
  means "decrement" rather than delete). A crash between steps 2 and 3 leaves an
  unreferenced blob that GC reclaims; a crash before step 3 never produces a
  dangling event.
- **Media route** as a **shared request handler attached to BOTH HTTPS
  listeners** — `server.ts:128` creates `https` (external) and, for a specific
  non-loopback host, `localHttps` (loopback); today each only gets an `upgrade`
  handler. The media handler must be installed on both, or the loopback / dev
  path (and the local HTTP bridge) won't serve media. Adding a `request` handler
  does **not** conflict with the `noServer` WS upgrade forwarding (upgrades and
  plain requests are separate events). It must implement:
  `GET` + `HEAD`; `Range` parsing → `206` + `Content-Range` + `Accept-Ranges`
  (and `416` on unsatisfiable range); `Content-Length`; strict `mediaId`
  validation (`^[a-f0-9]{64}$`, no path traversal); and stream backpressure.
  **Missing/GC'd id contract:** return `404` (never `500`) with
  `Content-Type: application/json` and body `{"error":"media_not_found"}`. The
  route **never** hands an error body to an image/video decoder — the app
  detects the non-image status and renders its own placeholder. (A `200` with a
  fallback image is explicitly rejected: it would poison content-addressed
  caches keyed by `mediaId`.)
- **Auth = capability token, not "unguessable URL."** A bearer-in-query is a
  capability that leaks via persisted event payloads, device logs, screenshots,
  and proxies — do **not** rely on secrecy. The token must be an HMAC scoped to
  `{mediaId, sessionId, deviceId, method, exp}` with a server-side signing key
  and a revocation **generation** counter, verified with **constant-time**
  comparison and strict expiry. Because tokens expire, **do not persist a signed
  `url` in the event** (see below) — the app mints/refreshes it at render time.
- **Token mint/refresh API.** The event carries no signed URL, so the app must
  obtain a fresh token before each fetch. Mint over the **existing authenticated
  WS connection** (not a new HTTP endpoint) with a request/response RPC:
  - Request `media.token.mint` `{ mediaId, sessionId, method: "GET"|"HEAD" }`.
    The caller identity (`deviceId`) and auth are taken from the already-
    authenticated socket (`auth_gate.ts`), never from the request body.
  - Response `{ token, expiresAt }` where `token = HMAC(signingKey, "v1|" +
    mediaId + "|" + sessionId + "|" + deviceId + "|" + method + "|" + exp + "|" +
    generation)`. **TTL is short (~60 s)** — long enough to start a fetch/range
    session, short enough to bound leaked-capability exposure.
  - The route recomputes the HMAC from the URL's `mediaId`+`t` and the socket-
    or query-bound `{sessionId, deviceId, method, exp, generation}`, compares in
    constant time, and enforces `exp` and the current `generation`. Bumping the
    server-side revocation `generation` invalidates every outstanding token.
  - On **replay** of an old event the app simply calls `media.token.mint` again;
    nothing signed is stored, so expiry never breaks history.
  - **Failure responses (route):** `401` missing/malformed token, `403`
    wrong-scope/revoked (stale generation)/tampered, `410` expired, `400`
    malformed `mediaId`. Mint RPC returns an error result for an unknown
    `mediaId` or a session/device not entitled to it.
- **New event kind `agent.media`.** Registration is more than one list — all of
  these must be updated or the event is dropped / unrendered:
  - server `EventKind` union (`server/src/protocol.ts`)
  - `EVENT_KINDS` + codec (`server/src/protocol/codec.ts`) — **note: there is
    NO Zod here.** The codec only validates the envelope and that `payload` is
    an object; media-payload fields get **no schema validation today**, so this
    spec must add explicit field validation (types, MIME allowlist, sha256
    format, size/dimension/duration bounds, reject unknown fields).
  - Flutter `EventKind` + wire codec (`app/lib/transport/protocol.dart`)
  - CLI renderer switch (`server/src/cli/render.ts` — exhaustive; needs a media
    fallback or `pi attach` silently omits media)

  Payload (note: **no persisted signed URL** — carry stable ids only):
  ```ts
  { mediaId: string;        // sha256, ^[a-f0-9]{64}$
    mime: string;           // from a server MIME allowlist
    kind: "image" | "video" | "audio";
    width?: number; height?: number; sizeBytes?: number; durationMs?: number;
    alt?: string;           // description / filename for a11y + fallback
    thumbMediaId?: string;  // optional poster/thumbnail (another stored blob)
    callId?: string;        // set when the media came from a tool result
  }
  ```
  The app builds the fetch URL as `/media/<mediaId>?t=<freshly-minted token>`;
  on replay of an old event it re-mints, so expiry never breaks history.
- **pi adapter** (`extractResultText` / `tool_execution_end`): when a tool result
  `content[]` contains `{type:"image",data,mimeType}`, persist the base64 to the
  media store and emit `agent.media` (alongside the existing `tool.call.end`
  text). Keep the text summary for the collapsed card.
- **ACP mapper** (`contentBlockText` callers): on `image`/`audio`/`resource`
  (blob) blocks, **copy the bytes into the content-addressed store at ingestion**
  (hash + write immediately) and emit `agent.media`. **Do NOT lazily serve
  `resource_link` / `file://` in phase 1** — a deferred file read violates the
  immutable content-addressed model (the file can change, vanish, or be
  symlink-swapped) and is an arbitrary-local-file disclosure risk. File/link
  references are deferred until canonical-path containment + symlink/TOCTOU +
  workspace-sandbox policy are specified (see Out / later phase).

**App (Flutter)**
- **Shared pinned `HttpClient`** — extract the WS client's fingerprint-verify
  callback (`ws_client.dart`) into a reusable client that all media loaders use
  (prerequisite; see the TLS section above).
- **`AgentMediaItem`** `ChatItem` (`app/lib/store/chat_items.dart`), folded from
  `agent.media`, and added to the **exhaustive `switch (item)`** in
  `app/lib/ui/session/chat_transcript.dart` (not `chat_message.dart` — that's
  where dispatch actually lives; missing it fails exhaustiveness).
- **Media renderer** (new widget alongside `AgentMessage`): image via a pinned
  loader (GIF animates natively), video via `video_player`, tap → fullscreen.
  **New deps** (`app/pubspec.yaml`) — `cached_network_image` / `video_player` /
  `chewie` are **not present today**; each carries native iOS/macOS/Android
  integration + its own TLS behavior. Image/GIF/thumbnail loaders wire to the
  pinned Dart `HttpClient`; `video_player` cannot (see the TLS section) and uses
  the prefetch-to-file path in phase 4. Treat adding them as real work, not a
  config line.

**Capability negotiation** — **does not exist yet.** `docs/CAPABILITIES.md`
marks it M4/future; real `hello`/ack messages (`server/src/ws/auth_gate.ts`,
`app/lib/store/connection.dart`) carry no `caps`. So either (a) treat cap
negotiation as a prerequisite spec, or (b) drop it from phase 1 and gate media
rendering on a fixed protocol-version bump instead. Phase 1 assumes (b).

### Out
- Assistant **generating** video/audio (agents don't). Only referenced/attached.
- **`file://` / `resource_link` serving** (deferred until path-containment,
  symlink/TOCTOU, and workspace-sandbox policy are specified).
- Real capability negotiation in `hello` (M4; see above).
- User→agent media uploads (that's pi `steer(text, images)` — a separate spec).
- Encryption-at-rest of the media store (inherits ARCHITECTURE.md open question).
- Rich image editing / annotation.

## Phasing

1. **Images, reference model** — media store (hash-at-ingestion) + dual-listener
   media route with token auth + `agent.media` across all four registration
   points + pi tool-result image blocks + ACP image/blob blocks + **shared
   pinned HTTP client** + Flutter image renderer. ~80% of the value.
2. **GIF** — falls out of phase 1 (animated `Image` via the pinned loader).
3. **Markdown image policy** — images already render, so this phase *secures*
   them: route markdown images through the pinned loader, apply an allowed-scheme
   policy, and decide external-host privacy behavior. (Not "enable images.")
4. **Video / audio** — fetch through the shared pinned `HttpClient` to a local
   temp file, then `video_player` plays the `file://` URI (native players can't
   use the Dart pinned client; see the TLS section). Range requests are already
   supported by the phase-1 route for the prefetch.
5. **`file://` / `resource_link`** — only after path-containment + symlink/TOCTOU
   + sandbox policy are specified.

Phases 1→2 are strictly ordered (2 depends on 1's loader). 3 and 4 are
independent of each other but both depend on 1.

## Risks / open questions

- **Token auth:** an HMAC-in-query is a *capability* that leaks via persisted
  payloads/logs/screenshots — that's why the token is NOT persisted, is scoped
  to `{mediaId, session, device, method, exp}`, uses a revocation generation,
  and is checked in constant time. The app re-mints on replay.
- **GC vs. resume:** deleting a session must clean up its media refs; GC needs
  durable metadata/refcounts, not just files. A GC'd id resolves to the route's
  `404 {"error":"media_not_found"}` contract (above), which the app maps to a
  **placeholder widget** — never an arbitrary non-image HTTP body handed to an
  image decoder, and never a `200` fallback image that would pollute the cache.
- **Decompression bombs:** cap decoded size + dimensions before allocate/write
  at ingestion.
- **Model without vision:** pi already annotates `[Current model does not
  support images…]`; input-side only, doesn't block display.
- **Thumbnail generation** for video posters — server-side (ffmpeg dep) vs.
  client first-frame (no dep). Defer to phase 4.

## Verification

- Server unit tests: pi image tool-result → `agent.media` emitted + blob stored
  (hash-addressed); ACP image/blob block → `agent.media`; **media payload
  validation** rejects bad MIME / bad sha256 / oversized / unknown fields;
  token verify passes valid + rejects expired/wrong-scope/tampered (constant
  time); route serves bytes, honours `Range` (`206`/`Content-Range`), returns
  `416` on bad range and a `404 {"error":"media_not_found"}` (not `500`, not a
  `200` fallback image) on GC'd/missing id;
  handler is reachable on **both** listeners; `cli/render.ts` renders a media
  fallback; session delete cleans up media refs.
- `pnpm typecheck` + `pnpm test` clean.
- App: `flutter analyze --fatal-infos` clean; the pinned HTTP client accepts the
  server fingerprint and **rejects a mismatching cert** for media fetches;
  `agent.media` folds to `AgentMediaItem` and renders via the pinned loader;
  `chat_transcript.dart` switch stays exhaustive.
- Manual: `read` a PNG in a real session → thumbnail in chat → fullscreen over
  the pinned self-signed endpoint.
