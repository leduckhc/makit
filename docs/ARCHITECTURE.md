# makit — Architecture

> Companion to [UX.md](./UX.md). This doc covers protocol, server internals,
> agent adapter shape, mobile app structure, and the experiment plan for the
> one open decision (how to drive agent CLIs).

## 0. Stack at a glance

| Layer            | Choice                                                       |
| ---------------- | ------------------------------------------------------------ |
| Desktop server   | **Node / TypeScript** (single `makit` binary via `pkg`/`bun`) |
| Mobile app       | **Flutter** (iOS first, Android free)                        |
| Wire protocol    | **WebSocket + JSON** (one socket per device ↔ server)        |
| Pairing          | QR + Noise-IK handshake, libsodium keypair per device        |
| Discovery        | mDNS on LAN; overlay VPN (Tailscale/headscale) for remote    |
| Agent adapter    | **Hybrid**: PTY scrape v1, native SDK/JSONL per-agent v2     |
| Persistence      | SQLite (server-side, single file in `~/.makit/`)              |
| Push             | APNs / FCM via optional hosted relay (opt-in)                |

---

## 1. Top-level topology

```
┌────────────┐    WSS+JSON      ┌──────────────────────────────┐
│  Phone     │ ───────────────▶ │  makit server (Node/TS)       │
│  (Flutter) │ ◀─────────────── │                              │
└────────────┘                  │  ┌────────────────────────┐  │
                                │  │ Session Manager        │  │
┌────────────┐                  │  │  ├─ Session (codex)    │  │
│  Tablet    │ ◀──── WSS ─────▶ │  │  ├─ Session (pi)       │  │
└────────────┘                  │  │  └─ Session (claude)   │  │
                                │  └────────────────────────┘  │
┌────────────┐                  │  ┌─ Agent Adapter (PTY/SDK)──┐
│  Desktop   │ ◀── local IPC ─▶ │  ┌─ Project Index ──────────┐│
│  tmux pane │                  │  ┌─ Device Registry ────────┐│
└────────────┘                  │  ┌─ Event Log (SQLite) ─────┐│
                                └──────────────────────────────┘
```

Every connected client holds **one WebSocket** to the server. The server is the
single source of truth for sessions, transcripts, and agent process lifecycle.

---

## 2. Wire protocol

WebSocket frames are JSON objects. Every message has:

```ts
type Envelope = {
  v: 1;                  // protocol version
  id: string;            // ULID, client-generated for requests
  t: MessageType;        // discriminator
  // ...type-specific fields
};
```

### 2.1 Message families

| Family       | Direction    | Examples                                                 |
| ------------ | ------------ | -------------------------------------------------------- |
| `hello`      | C→S, S→C     | Handshake, capability negotiation, resume cursor         |
| `sub`        | C→S          | Subscribe/unsubscribe to session(s) or project(s)        |
| `event`      | S→C          | Append-only stream of session events (see §3)            |
| `cmd`        | C→S          | User intent: send-message, approve, cancel, spawn, kill  |
| `ack` / `err`| S→C          | Response to a `cmd` with its `id`                        |
| `presence`   | S→C          | Which devices are currently subscribed to a session      |
| `ping`/`pong`| both         | Keepalive, RTT measurement                               |

### 2.2 Resume / offline

- Client persists last `event.seq` per session locally.
- On reconnect: `hello { resumeFrom: { [sessionId]: lastSeq } }`.
- Server streams missed events from the SQLite event log, then live.
- Queued outbound `cmd`s are flushed in order with their original `id`s; the
  server dedupes by `id` (idempotent commands).

### 2.3 Auth

- TLS terminated at the server (self-signed cert pinned at pair time).
- First frame after socket open is `hello { deviceId, sig }` where `sig` is
  a Noise-IK / Ed25519 challenge response over a server-issued nonce.
- Device pubkey must be in `device_registry`. Unknown device → close with
  `4001 unpaired`.

---

## 3. Domain model

```ts
type Project = {
  id: string;
  name: string;
  path: string;            // absolute cwd on server host
  pinned: boolean;
  lastActivityAt: number;
};

type Session = {
  id: string;
  projectId: string;
  agent: "codex" | "pi" | "claude" | "shell" | string;
  title: string;           // derived from first user message
  status: "idle" | "running" | "awaiting-input"
        | "awaiting-approval" | "error" | "exited";
  approvalPolicy: "yolo" | "ask-on-risky" | "ask-always";
  createdAt: number;
  userId: string;          // single user in v1, reserved for team mode
};

type Event = {
  seq: number;             // monotonic per session
  sessionId: string;
  ts: number;
  kind: EventKind;
  payload: unknown;        // discriminated by kind
};

type EventKind =
  | "user.message"         // text the user sent
  | "agent.message"        // assistant prose
  | "agent.thinking"       // optional reasoning trace
  | "tool.call.start"      // { name, args, callId }
  | "tool.call.delta"      // streaming stdout/stderr chunk
  | "tool.call.end"        // { callId, exitCode, summary, artifacts }
  | "approval.request"     // { callId, risk, preview }
  | "approval.decision"    // { callId, decision, by: deviceId }
  | "session.status"       // status transition
  | "session.error";
```

Events are **append-only** and authoritative. The phone's chat UI is a pure
projection of the event stream. Tool cards are derived by folding
`tool.call.start` + `delta`s + `end` into a single card.

---

## 4. Server internals (Node/TS)

```
src/
├── server.ts               // WebSocket server, TLS, hello/auth
├── protocol/               // Zod schemas for every envelope
├── sessions/
│   ├── SessionManager.ts   // lifecycle, status, fan-out
│   ├── Session.ts          // one session = one agent process + event log
│   └── policies.ts         // approval policy enforcement
├── adapters/
│   ├── AgentAdapter.ts     // interface (see §5)
│   ├── PtyAdapter.ts       // generic PTY scrape
│   ├── CodexAdapter.ts     // codex JSONL (v2)
│   ├── PiAdapter.ts        // pi SDK / JSONL (v2)
│   └── ClaudeAdapter.ts    // claude-code SDK (v2)
├── projects/
│   └── ProjectIndex.ts     // discover repos, watch cwd, pin/hide
├── devices/
│   └── DeviceRegistry.ts   // paired devices, revocation
├── pairing/
│   ├── qr.ts               // render QR with pairing token
│   └── handshake.ts        // Noise-IK
├── transport/
│   ├── mdns.ts             // advertise `_makit._tcp.local`
│   └── relay.ts            // optional hosted relay for push + NAT fallback
├── storage/
│   └── db.ts               // SQLite (better-sqlite3); migrations
└── cli.ts                  // `makit serve`, `makit pair`, `makit sessions`, ...
```

Key invariants:

- **Session has one writer** (the agent process), **N readers** (devices).
  Fan-out is in-memory pub/sub keyed by `sessionId`.
- All events are written to SQLite **before** being fanned out. Reconnect/resume
  always reads from the log, never from memory.
- Server never blocks on a client. Slow client → drop subscription, force
  resume on reconnect.

---

## 5. Agent adapter interface

The single seam that decides whether we can support a new agent CLI:

```ts
export interface AgentAdapter {
  readonly agent: string;             // "codex" | "pi" | ...
  start(opts: SpawnOpts): Promise<void>;
  send(input: UserInput): Promise<void>;          // user message / keystrokes
  approve(callId: string, decision: ApprovalDecision): Promise<void>;
  cancel(): Promise<void>;
  kill(signal?: NodeJS.Signals): Promise<void>;

  // Push-out: adapter emits normalized Events into the session log.
  on(event: "event", listener: (e: Omit<Event, "seq" | "sessionId">) => void): this;
  on(event: "exit", listener: (code: number | null) => void): this;
}
```

Four implementations ship today (`server/src/adapters/`); the adapter
interface is identical so the rest of the server doesn't care which one a
session uses:

### 5.1 `PiAdapter` (World A — direct spawn)

- Drives `pi --mode rpc` as a long-running JSON-RPC subprocess (one per
  Session, started lazily on first send, killed on Session shutdown).
- Gets pi's slash commands, skills, extensions, prompt templates, mid-turn
  steering, abort, model switching, and compaction — all native, no ANSI
  guessing.

### 5.2 `MirrorAdapter` (World B — tail a real terminal pane)

- Bridges a **real `pi` TUI** already running in a terminal-multiplexer pane
  (e.g. herdr) to a makit session, so the phone sees it as normal chat.
- Read: tails the pi session `.jsonl` the TUI writes. Write: injects the
  phone's text into the pane via send-text + Enter. No second pi process is
  spawned for the chat stream, so there's no double-writer corruption.

### 5.3 `IngestAdapter` (World D — pushed in by an extension)

- A session whose events are pushed in by the `makit-mirror` pi extension
  (loaded into the user's real `pi`, TUI or otherwise) rather than produced by
  a makit-spawned process.

### 5.4 `StubAdapter` (tests)

- Deterministic fake (fixed-delay echo + markdown sample reply) used by the
  app's E2E suite; no real agent involved.

*(The original PTY-vs-native Spike 0 in §10 predates World A/B/D and is
historical — makit ships pi-only, so the PTY/Codex/Claude comparison there
never shipped.)*

---


## 6. Mobile app (Flutter)

```
lib/
├── main.dart
├── app/                    // routing, theming, keyboard shortcuts
├── pairing/                // QR scan, mDNS browse, VPN check
├── transport/
│   ├── ws_client.dart      // reconnect, resume, queue
│   └── protocol.dart       // codegen-ish from shared JSON schema
├── store/                  // Riverpod (or Bloc) state
│   ├── projects.dart
│   ├── sessions.dart
│   ├── events.dart         // event-log projection per session
│   └── presence.dart
├── ui/
│   ├── home/               // Projects → Sessions list
│   ├── session/            // chat view + composer
│   ├── tool_card/          // collapsed card → fullscreen drilldown
│   ├── diff_viewer/
│   ├── composer/           // slash palette, @-mentions, voice
│   └── settings/
└── platform/
    ├── push.dart           // APNs/FCM tokens
    ├── voice.dart          // dictation
    └── secure_storage.dart // device keypair
```

State is a pure **projection of the event stream**:
`events[sessionId] → derived(messages, toolCards, status)`.
Same render path for live and replayed events.

---

## 7. Pairing flow (concrete)

1. User runs `makit serve` on desktop.
   - Server generates a long-term server keypair on first run (stored in
     `~/.makit/server.key`).
   - Advertises `_makit._tcp.local` via mDNS with TXT record `fp=<server-fp>`.
2. User taps "Pair device" in app → opens camera.
3. `makit pair` (or the server's status TUI) prints a QR encoding:
   ```
   makit://pair?host=<lan-ip-or-overlay-hostname>&port=<p>&fp=<server-fp>&t=<short-lived-token>
   ```
4. Phone parses QR, opens WSS to host:port, pins `fp`, sends
   `hello { pair: { token, devicePub } }`.
5. Server verifies token (single-use, 5-min TTL), stores `devicePub` in
   `device_registry` with a user-chosen label, responds with paired ack.
6. App stores `{ host, fp, devicePriv, serverPub }` in secure storage.
7. Subsequent connects: Noise-IK handshake using stored keys; no token needed.

Remote access: same flow, but `host` resolves through Tailscale/overlay DNS.
The pair QR can be regenerated after the user joins the overlay so it carries
the overlay hostname instead of LAN IP.

---

## 8. Approvals (server-side enforcement)

- Adapter emits `tool.call.start` with a `risk: "safe" | "risky" | "destructive"`
  classification (PTY adapter uses a per-CLI rule table; native adapters use
  the agent's own classification when available).
- `SessionManager` checks `approvalPolicy`:
  - `yolo`: auto-approve all.
  - `ask-on-risky`: auto-approve `safe`, emit `approval.request` for the rest.
  - `ask-always`: emit `approval.request` for every call.
- While awaiting: session status flips to `awaiting-approval`, push fires.
- First device to send `cmd: approve` wins; decision is broadcast as
  `approval.decision`.
- Adapter is told to proceed or to inject a cancel into the agent.

---

## 9. Notifications & relay

- Server can run **standalone** (LAN/VPN only, no push) — fully functional.
- Optional **hosted relay** (`relay.makit.dev` or self-hosted) does two things:
  1. Forwards APNs/FCM pushes (device registers token; server sends push
     intents to relay; relay holds Apple/Google creds).
  2. Acts as a NAT-traversal fallback for users who don't want Tailscale.
- Relay never sees plaintext: it only carries opaque envelopes; push payloads
  are minimal ("session X needs you") with the body fetched over WSS when the
  app opens.

---

## 10. Spike 0 — agent adapter experiment

**Goal:** decide whether v1 ships pure PTY, pure native-per-agent, or hybrid.

**Setup:** one throwaway branch, two adapters wired behind the same interface:

1. `PtyAdapter` driving `codex` and `claude-code` via node-pty + xterm-headless.
2. `CodexAdapter` driving `codex` via its JSONL event stream.

**Tasks to run through both:**

- Send a multi-turn prompt, observe message events.
- Trigger a file edit (tool call), observe diff fidelity in the card.
- Trigger a shell command with streaming output.
- Trigger an approval-required action.
- Cancel mid-tool-call.
- Crash the agent, observe recovery.

**Success criteria for "PTY is enough for v1":**

- Tool-call boundaries detected ≥95% reliably across both CLIs.
- Diff/file output reconstructable without ANSI artifacts.
- Approval gating injectable before the side effect (not after).
- < 50ms added latency vs raw CLI.

If PTY fails any of these for an agent, that agent gets a native adapter in v1.
Other agents stay on PTY until they hurt.

**Deliverable:** `docs/SPIKE-0.md` with the matrix filled in and a
recommendation. Then we lock the v1 adapter set.

---

## 11. Build & distribution

- Server: `bun build` → single binary, `brew tap makit/tap && brew install makit`.
  Also `npx makit serve` for quick try.
- Mobile: TestFlight (iOS) + internal track (Android) during v0.
- Versioning: protocol `v` is independent of app/server semver; server must
  support `v` and `v-1` for graceful upgrades.

---

## 12. v1 milestones

1. **M0 — Skeleton**: WS server, pairing, one fake echo "agent", Flutter shell
   renders messages. *No real agent yet.*
2. **M1 — Spike 0**: PTY vs native, pick adapter set.
3. **M2 — Real sessions**: spawn codex/pi via chosen adapter, full event
   stream, approvals, mirror to desktop pane.
4. **M3 — Projects & multi-session**: project index, home screen, presence.
5. **M4 — Resume/offline**: event log, reconnect, queued commands.
6. **M5 — Notifications** ✅: actionable lock-screen approvals (SPEC-08) + content-free APNs wake (SPEC-07). See [NOTIFICATIONS.md](NOTIFICATIONS.md) and [PUSH.md](PUSH.md).
7. **M6 — Polish**: slash palette, @-mentions, voice, diff viewer.

---

## Open questions deferred

- Encryption-at-rest for the event log? (probably yes; SQLCipher.)
- How much of the desktop tmux pane content do we mirror back into the phone
  (just agent CLI output, or the whole pane including user shell history)?
- Web client: same WS protocol, but auth via short-lived JWT from a paired
  device? Or require its own pairing?
- Team mode: per-session ACL granularity (read / write / approve)?
