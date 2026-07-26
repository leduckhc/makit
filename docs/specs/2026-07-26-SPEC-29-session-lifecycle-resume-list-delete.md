# SPEC-29 — Adapter-native session lifecycle (resume · list · delete · fork)

**Status:** Proposed · **Priority:** P1 · **Surface:** server (`server/src/`), wire protocol (`protocol.ts`), Flutter store (`app/lib/store/`)
**Depends on:** SPEC-27 (pi-over-ACP via `pi-acp`; codex over `app-server`; both projected into one config model), SPEC-17 (durable event log + rehydration), SPEC-19 (adapter/manager decomposition).

> **Implementation status (2026-07-26).**
> - **Resume (both transports) — DONE.** Adapter capability negotiation
>   (`SessionCapabilities`), native id capture (`agentSessionId`), persistence
>   (`agent_session_id` column), capability-gated `reattachSession`, ACP
>   silent-load, codex `thread/resume`, and the app's auto-attach-on-cold-`sub`
>   are implemented + tested (server 437 tests, live pi-acp e2e verified).
> - **List (adapter-native) — DONE.** `session.list` now serves
>   `listAgentSessions` (ACP `session/list` + codex `thread/list`); codex
>   sessions appear for the first time.
> - **Delete / fork cmds — PENDING.** `session.delete` + `session.fork`
>   (plan step 7) are not yet wired; the adapter/back-end support
>   exists (codex `thread/delete`/`thread/fork`, ACP `session/delete`).
> - **Archive (decision 6, updated) — DONE.** `session.archive` /
>   `session.unarchive` are wired: a persisted `archived` flag (new nullable
>   `archived` column) that excludes the session from the active
>   `sessions.snapshot` (`listSessions()`), survives a restart, keeps the event
>   log + resume handle, and is reversible. makit-side only — the underlying
>   session/thread is left intact + directly resumable (no archived-thread
>   resume edge case); the `capabilities.archive` flag is recorded for a future
>   native-archive option. Covered by server tests + app codec test.
> - **Deviation from decision 5:** listing uses a **throwaway connection per
>   agent** (the existing `probe*` pattern in `acp.ts`/`codex.ts`), not a method
>   on a live adapter — a cold list needs no live session and this matches how
>   capability probing already works. `pi-sessions.ts` is **retained** (legacy
>   `attachPiSession` still uses it) rather than deleted; it is simply no longer
>   on the `session.list` path.
**Prerequisite / assumption:** **Two transports, one lifecycle model.** pi runs over ACP via `pi-acp` (`AcpAdapter`); codex runs native via `codex app-server` (`CodexAppServerAdapter`). Both back ends **already expose** first-class session persistence — this spec surfaces it through one adapter-agnostic seam. **No SDK/binary upgrade is required** (see Evidence).

---

## Problem

makit persists a session's **transcript** durably (`SqliteEventStore`) and
rehydrates sessions as cold, read-only history after a server restart
(`manager.ts` `rehydrate()`), but it **cannot bring the agent back to life**:

1. **Resume is a no-op stub.** `AcpAdapter.start()` explicitly discards
   `opts.resumeSessionPath` — `log.warn("resumeSessionPath ignored (ACP resume
   not wired yet)")` — and always calls `session/new`. So every reconnection
   starts a *fresh* agent context, losing the conversation the agent itself
   holds.
2. **No resume handle is ever captured.** The ACP `sessionId` returned by
   `session/new` (`acp.ts`, `this.acpSessionId`) and codex's `threadId`
   (`codex.ts`, `this.threadId`) live only in adapter memory and are never
   persisted. The DB has a `resume_session_path` column but nothing populates it
   for a normally-spawned session.
3. **`reattachSession()` is dead on arrival.** It requires
   `session.resumeSessionPath` **and** `agent === "pi"`, and then builds an
   `AcpAdapter` — the very adapter that ignores the resume path. The
   "native pi adapter resumes from transcript" comment describes code that was
   removed in SPEC-27. Result: after a server restart **no** session can
   continue; sending a message hits the `DetachedAdapter` and emits
   `session.error`.
4. **The app never triggers reattach.** `store.dart` `attachSession()` only
   sends the legacy `{projectId, piSessionId}` form; nothing sends the
   `{sessionId}` form that reaches `reattachSession()`.
5. **Session discovery scrapes files.** `pi-sessions.ts` reads pi's on-disk
   JSONL transcripts directly (slug algorithm copied from pi's internals,
   header parsing, `statSync` mtime). It is pi-specific, brittle to pi's
   on-disk format, and returns **nothing** for codex.

Net: **app restart survives** (the app is a thin client that re-`sub`s and
replays from the server log), but **server restart freezes every session as
read-only** — the single biggest gap in the persistence story.

## Evidence (verified against the live toolchain)

Both back ends already implement the full lifecycle. Confirmed by probing the
installed binaries, not just the spec:

- **`pi-acp` v0.0.32** `initialize` advertises:
  ```json
  "agentCapabilities": {
    "loadSession": true,
    "sessionCapabilities": { "list": {}, "delete": {} }
  }
  ```
  `session/list` returns real `{sessionId, cwd, title, updatedAt}` rows; it does
  **not** advertise `sessionCapabilities.resume` → pi uses `session/load`
  (which **replays** history).
- **`codex app-server` (codex-cli 0.145.0)** exposes
  `thread/start`, **`thread/resume`**, **`thread/fork`**, **`thread/delete`**,
  `thread/archive`, `thread/name/set`, **`thread/list`**. `thread/resume
  {threadId}` returns the thread (with `cwd`, `path`, `preview`, `status`) and
  does **not** replay history.
- **The pinned SDK** `@agentclientprotocol/sdk@^1.3.0` already exposes
  `ClientSideConnection.{loadSession,resumeSession,listSessions,deleteSession,forkSession}`
  and the `LoadSessionRequest`/`SessionInfo`/capability types.

## Goal

One adapter-agnostic **session lifecycle** seam, mapped to each back end's
native protocol, that makes:

1. **Resume across server restart** work for **both** pi and codex — a
   reconnecting client can keep chatting in the same agent context.
2. **Session listing** an adapter-native capability (replaces the pi-only
   file-scraping in `pi-sessions.ts`), so discovery works for codex too.
3. **Session delete** durable (drops the agent's session/thread, the makit
   session, and the event log together).
4. **Session fork** available where the back end supports it (codex
   `thread/fork` today; ACP `session/fork` when `pi-acp` ships it) — a natural
   fit for makit's existing split-session flow.

Every capability is **negotiated** (advertised by the adapter) and **optional**:
an adapter that lacks a capability degrades exactly as today (history-only), and
the wire/app contract is unchanged for unaffected paths — **backward
compatible**.

---

## Decisions (frozen)

> **Decision 6 UPDATED (2026-07-26) — archive, don't hard-delete.** The primary
> destructive action is **archive** (recoverable), not delete. `session.archive`
> sets a persisted `archived` flag on the makit session, stops the live agent
> (`adapter.kill()`), and swaps in the `DetachedAdapter`. It is **makit-side
> only** — it does **not** call any back-end native archive (codex
> `thread/archive` is deliberately avoided so the underlying thread stays
> directly resumable; the transcript + event log + resume handle are **kept**,
> never destroyed). Archived sessions are **excluded from the active session
> list** (`listSessions()` → `sessions.snapshot`) but survive a restart
> (rehydration keeps them archived) and are restored with `session.unarchive`
> (clears the flag; the session stays cold until the next subscribe re-attaches
> it). No rows are deleted from the event log. A truly permanent hard-delete
> (SQL delete + agent `thread/delete`/`session/delete`) is deferred to a
> separate explicit
> "delete permanently" action and is NOT wired in this pass.

1. **Capability negotiation lives on the adapter, not on `agent === "pi"`.**
   The `AgentAdapter` seam gains a `capabilities()` (or `readonly capabilities`)
   descriptor: `{ resume, list, delete, fork }`. `AcpAdapter` derives it from
   the ACP `initialize` response (`agentCapabilities.loadSession` /
   `sessionCapabilities.resume|list|delete|fork`); `CodexAppServerAdapter`
   reports `{ resume:true, list:true, delete:true, fork:true }` (its methods are
   always present in the supported `app-server`). `DetachedAdapter` reports all
   `false`. **No call site branches on the agent id.**

2. **Resume preference: `resume` (no replay) > `load` (replay).** When an
   adapter advertises native resume-without-replay, use it — makit already owns
   the transcript in SQLite, so replay is wasted work and a dedup hazard.
   - **codex** → `thread/resume { threadId, cwd }` (no replay). ✅ clean.
   - **pi** → `session/load { sessionId, cwd, mcpServers: [] }`, which **does**
     replay. Because makit's event log is authoritative, the load replay is
     consumed in **silent mode** (decision 3). If `pi-acp` later advertises
     `sessionCapabilities.resume`, the adapter automatically prefers it.

3. **`session/load` runs in silent mode.** During a resume-via-load, the
   `AcpAdapter` sets a `loading` flag; its `sessionUpdate` client handler
   **drops all `session/update` notifications** until the `loadSession` promise
   resolves, then clears the flag and resumes normal streaming. The agent's
   history is used only to rehydrate the *agent's* in-process context — it is
   **never** re-appended to the store (which would duplicate every past turn and
   re-fan-out on the hot path). makit's SQLite log remains the single source of
   truth for what the client sees.

4. **Persist the native session/thread id, not a file path.** The session's
   resume handle is a transport-neutral **`agentSessionId`** (ACP `sessionId` /
   codex `threadId`), stored in a **new nullable `agent_session_id` column**
   (added via the store's additive `ALTER TABLE` migration; the legacy
   `resume_session_path` column is left intact for back-compat but is no longer
   the resume handle). The adapter reports its native id via an `agentSessionId`
   getter so `Session`/the store persist it as soon as `start()` completes.
   **Legacy break:** rows persisted before this change that have only
   `resume_session_path` (old native-pi transcript path) cannot resume — ACP
   resume is keyed by the ACP `sessionId`, not a transcript path — so
   `reattachSession` leaves them history-only (they are not lost, just not
   resumable). This is intentional; the old native-pi resume path was removed in
   SPEC-27.

5. **`session.list` becomes adapter-native, project-scoped.** The manager gains
   `listAgentSessions(projectId)` that, for each agent the host offers, calls the
   adapter's `listSessions({ cwd })` (ACP `session/list` filtered by `cwd`;
   codex `thread/list` filtered by `cwd`) and normalizes to the existing
   `PiSessionMeta` wire shape (renamed conceptually to `AgentSessionMeta`, wire
   fields unchanged for back-compat: `piSessionId` now carries the native id).
   `pi-sessions.ts` file-scraping is **removed** once the ACP path is proven;
   `parseTranscript` (used for backfill in the legacy attach flow) is retired
   with it because silent-load supersedes transcript backfill.

6. **`session.delete` is a new cmd** (`session.kill` stays "stop the process,
   keep history"). `session.delete` calls the adapter's `deleteSession(id)`
   (ACP `session/delete`; codex `thread/delete`) **and** removes the makit
   session + its events (`SqliteEventStore.deleteSession`). Best-effort on the
   agent side (a failed agent-delete still removes the makit session, with a
   logged warning).

7. **Fork is exposed only where advertised.** A new `session.fork` cmd maps to
   the adapter's `forkSession(id)` when `capabilities.fork` is true; it creates a
   fresh makit session seeded with the fork's `agentSessionId`. codex supports
   it now; pi returns "not supported" until `pi-acp` adds `session/fork`. This
   dovetails with SPEC-28's split-session UI (fork the *conversation*, not just
   share a worktree) but the UI wiring is **out of scope here** — this spec ships
   the server/wire capability only.

8. **App auto-resumes cold sessions.** When the app `sub`s to a session whose
   status is `exited`/cold and whose DTO reports `resumable: true`, it issues
   `session.attach { sessionId }` before/So the first send lands on a live agent.
   A non-resumable cold session renders read-only (as today).

---

## Current-state anchors (real code this reshapes)

- `server/src/adapters/adapter.ts` — `AgentAdapter` interface + `SpawnOpts`
  (`resumeSessionPath`). Gains `capabilities`, `agentSessionId`, `listSessions`,
  `deleteSession`, `forkSession`; `SpawnOpts.resumeSessionPath` →
  `resumeAgentSessionId`.
- `server/src/adapters/acp.ts` — `start()` resume stub (line ~174), captured
  `acpSessionId`, `buildClient().sessionUpdate`. Gains silent-load, capability
  capture from `initialize`, `listSessions`/`deleteSession`/`forkSession`.
- `server/src/adapters/codex.ts` — `start()` `thread/start`, captured
  `threadId`. Gains `thread/resume` on start-with-id, `thread/list`,
  `thread/delete`, `thread/fork`, capability report.
- `server/src/adapters/detached.ts` — reports all-false capabilities.
- `server/src/session.ts` — `resumeSessionPath` → `agentSessionId`; `toMeta()`
  persists it; DTO gains `resumable` (derived, see protocol).
- `server/src/manager.ts` — `reattachSession()` (capability-gated, both
  transports), `listAgentSessions()`, `deleteSession()`, `forkSession()`;
  `attachPiSession()`/file-scrape path removed.
- `server/src/storage/sqlite_event_store.ts` — `SessionMeta.resumeSessionPath`
  → `agentSessionId` (same nullable column, no migration).
- `server/src/pi-sessions.ts` — **removed** (replaced by adapter-native listing);
  `listPiSessions`/`parseTranscript`/`summarize` deleted.
- `server/src/ws/commands/session.ts` — `session.list` re-pointed at
  `listAgentSessions`; new `session.delete`, `session.fork`; `session.attach`
  `{sessionId}` path kept, legacy `{piSessionId}` path removed.
- `server/src/protocol.ts` — `CmdKind` gains `session.delete`, `session.fork`;
  `SessionDTO` gains `resumable`.
- `app/lib/store/store.dart`, `models.dart`, `connection.dart` — auto-attach on
  cold `sub`; `deleteSession`/`forkSession`; `PiSessionMeta` unchanged on the
  wire.

---

## Target model

### Adapter seam (`server/src/adapters/adapter.ts`)

```ts
export interface SessionCapabilities {
  /** Native resume without replay (ACP session/resume, codex thread/resume). */
  resume: boolean;
  /** Enumerate prior sessions (ACP session/list, codex thread/list). */
  list: boolean;
  /** Delete a session/thread (ACP session/delete, codex thread/delete). */
  delete: boolean;
  /** Fork a session/thread (codex thread/fork; ACP session/fork when available). */
  fork: boolean;
  /** Replay-based load (ACP loadSession) — used when `resume` is unavailable. */
  load: boolean;
}

export interface AgentSessionInfo {
  id: string;           // native session/thread id
  cwd: string;
  title?: string;
  updatedAt?: number;   // epoch ms
  messageCount?: number;
  preview?: string;
}

export interface AgentAdapter extends EventEmitter {
  readonly agent: string;
  readonly capabilities: SessionCapabilities;
  /** Native session/thread id once start() resolves; undefined for Detached. */
  readonly agentSessionId?: string;
  start(opts: SpawnOpts): Promise<void>;
  // …existing send/sendAction/cancel/kill…
  /** Enumerate prior sessions for a cwd (only when capabilities.list). */
  listSessions?(opts: { cwd: string }): Promise<AgentSessionInfo[]>;
  /** Delete a session/thread by native id (only when capabilities.delete). */
  deleteSession?(id: string): Promise<void>;
  /** Fork a session/thread; resolves to the new native id (capabilities.fork). */
  forkSession?(id: string): Promise<string>;
}

export interface SpawnOpts {
  // …existing…
  /** Resume/load an existing agent session by its native id. Replaces the old
   *  `resumeSessionPath`. When set, start() resumes (no session/new). */
  resumeAgentSessionId?: string;
}
```

### Protocol (`server/src/protocol.ts`)

```ts
export type CmdKind =
  | "send.message" | "session.action" | "cancel"
  | "session.spawn" | "session.spawnLinked"
  | "session.list" | "session.attach"
  | "session.kill"
  | "session.delete"   // NEW — durable delete (agent + makit + events)
  | "session.fork"     // NEW — fork a conversation (when supported)
  | "session.setAgent"
  // …unchanged…

export interface SessionDTO {
  // …existing…
  /** True when this (possibly cold) session can be brought back to a live
   *  agent — i.e. it has an agentSessionId AND its adapter advertises
   *  resume|load. Drives the app's auto-attach on cold `sub`. */
  resumable: boolean;
}
```

`session.list` ack shape is **unchanged** (`{ sessions: AgentSessionMeta[] }`
with the existing `piSessionId/name/preview/messageCount/lastActivityAt`
fields; `piSessionId` now carries the transport-native id).

### Server behavior

**`AcpAdapter`**
- In `start()`: after `initialize`, capture `capabilities` from
  `agentCapabilities`. If `opts.resumeAgentSessionId`:
  - `capabilities.resume` → `conn.resumeSession({ sessionId, cwd, mcpServers: [] })`.
  - else `capabilities.load` → set `this.loading = true`,
    `conn.loadSession({ sessionId, cwd, mcpServers: [] })`, clear on resolve.
  - else fall through to `newSession` (degraded).
  `this.acpSessionId` is set to the resumed id; expose via `agentSessionId`.
- `sessionUpdate` handler: `if (this.loading) return;` (drop replay).
- `listSessions({cwd})` → `conn.listSessions({ cwd })` → map `SessionInfo[]`.
- `deleteSession(id)` → `conn.deleteSession({ sessionId: id })`.
- `forkSession` → present only if `capabilities.fork`.

**`CodexAppServerAdapter`**
- `capabilities = { resume:true, list:true, delete:true, fork:true, load:false }`.
- In `start()`: if `opts.resumeAgentSessionId`, call
  `thread/resume { threadId, cwd }` instead of `thread/start`; set
  `this.threadId` from the response. (No replay → no silent mode needed.)
- `listSessions({cwd})` → `thread/list {}` filtered to matching `cwd`, mapped to
  `AgentSessionInfo` (`preview`→preview, `updatedAt`→ms).
- `deleteSession(id)` → `thread/delete { threadId: id }`.
- `forkSession(id)` → `thread/fork { threadId: id }` → new thread id.

**`SessionManager`**
- `reattachSession(sessionId)`: gate on
  `session.agentSessionId && (adapter.capabilities.resume || .load)` — **not**
  the agent id. Build the real adapter via `buildAdapter(session.agent)`, start
  with `resumeAgentSessionId`. Preserve the durable `seq` space (store assigns
  next seq on append, unchanged).
- `listAgentSessions(projectId)`: for the project's cwd, call each offered
  agent's `listSessions` (skip agents without `capabilities.list`), tag
  `attached` against live sessions, sort newest-first.
- `deleteSession(sessionId)`: `adapter.deleteSession?.(agentSessionId)`
  best-effort → `store.deleteSession(sessionId)` → drop from `this.sessions`.
- `forkSession(sessionId)`: `adapter.forkSession?.(agentSessionId)` → create a
  new makit session seeded with the returned id.

### Flutter (`app/lib/store/`)

- On cold `sub` (`store.dart` `_sendSub`): if the target session's DTO is cold
  and `resumable`, first send `session.attach { sessionId }`, await the ack,
  then `sub`. A non-resumable cold session stays read-only.
- `deleteSession(id)` / `forkSession(id)` request helpers; `session.list`
  parsing unchanged (`PiSessionMeta.fromJson`).

---

## Plan (TDD)

Build order respects the dependency chain; each step is independently
verifiable and lands with a failing-first test.

1. **Adapter capabilities + `agentSessionId` (no behavior change).**
   → test: `AcpAdapter` capability capture from a fake `initialize`;
   `CodexAppServerAdapter.capabilities` constant; `DetachedAdapter` all-false.
   → verify: existing adapter tests green; new getters populated after `start()`.
2. **Persist `agentSessionId` (rename from `resumeSessionPath`).**
   → test: `SqliteEventStore` round-trips `agentSessionId`; `Session.toMeta()`
   persists the live adapter's id; rehydrate restores it.
   → verify: `sqlite_event_store.test.ts`, `session.test.ts` green; no DB
   migration needed (same column).
3. **codex resume (`thread/resume`).**
   → test: `codex.test.ts` — `start({resumeAgentSessionId})` sends
   `thread/resume` (not `thread/start`) and adopts the returned thread id.
   → verify: no replay emitted; first `send` uses the resumed thread.
4. **ACP silent-load resume (`session/load`).**
   → test: `acp.test.ts` — resume path calls `loadSession`; `session/update`
   notifications arriving during load are **dropped** (store not appended);
   post-resolve updates stream normally. Prefer `resumeSession` when advertised.
   → verify: no duplicate events in the store after resume.
5. **`reattachSession` capability-gated, both transports.**
   → test: `manager.test.ts` — a rehydrated pi session and a rehydrated codex
   session each re-attach and accept a new turn; a `DetachedAdapter`-only /
   no-`agentSessionId` session throws "history only".
   → verify: `seq` continues past the persisted max; mobile↔desktop handoff
   after restart works end-to-end (extend `test/e2e-server.ts` stub with a
   resumable capability).
6. **Adapter-native `session.list`; remove `pi-sessions.ts`.**
   → test: `manager.test.ts` — `listAgentSessions` merges pi + codex results,
   filters by cwd, marks `attached`. Delete `pi-sessions.test.ts`.
   → verify: `session.list` ack shape unchanged; codex sessions now appear.
7. **`session.delete` + `session.fork` cmds.**
   → test: `ws/commands/session` — delete removes agent session + makit session
   + events; fork (codex) returns a new session id; fork on pi errors cleanly.
   → verify: `command_router`/`server.test.ts` green.
8. **App auto-attach on cold `sub` + delete/fork helpers.**
   → test: store unit test — cold `resumable` session triggers `session.attach`
   before `sub`; non-resumable does not.
   → verify: `flutter test --no-pub` green (VM-runnable per AGENTS.md).

---

## Risks & notes

- **Replay duplication (ACP `session/load`).** The core hazard. Mitigated by
  silent mode (decision 3); the test in step 4 asserts zero store growth during
  load. If a future `pi-acp` adds `session/resume`, the adapter auto-prefers it
  and silent mode becomes dead weight (kept for other load-only agents).
- **`cwd` drift on resume.** A session's worktree may be pruned/renamed between
  restarts. `reattachSession` already resolves a safe cwd (session worktree if
  still an active worktree on disk, else project root); reuse that logic and
  pass it to `resume`/`load`/`thread/resume`.
- **codex thread ↔ makit session identity.** codex `thread/list` returns
  threads for the whole codex home, not scoped to makit. Filter by `cwd` and by
  presence of a stored `agentSessionId` so unrelated codex CLI threads don't
  leak into makit's list unless the user explicitly browses them.
- **Capability drift across versions.** Never assume; always read the
  `initialize` response for ACP and treat codex methods as present only for the
  supported `app-server` (the availability gate in SPEC-27 already fingerprints
  the binary). An adapter whose probe fails degrades to history-only.
- **`session.kill` vs `session.delete`.** Keep both. Kill = stop process, keep
  transcript (resumable later). Delete = destroy everywhere. The app must not
  conflate them.

## Out of scope

- SPEC-28 split-session UI wiring for `session.fork` (server capability only
  here).
- Cross-device push/notification of session-list changes (`SessionInfoUpdate`
  streaming) — future enhancement.
- Importing *third-party* (non-makit) agent sessions into makit's own
  event-log model — `session/load` of a foreign session would lack makit's
  bridge/MCP wiring (see the ACP `session-resume` RFD's own caveat). We only
  resume sessions makit itself created.
- Pagination of `session.list` (ACP/codex both cursor-paginate; makit returns
  the first page until a session browser needs more).
