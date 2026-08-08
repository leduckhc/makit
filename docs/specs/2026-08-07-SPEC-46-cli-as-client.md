# SPEC-46 — The CLI is a client: sessions from the terminal, handoff as a command

**Status:** Draft · **Priority:** P1 · **Branch:** `feat/cli-client`
**Depends on:** SPEC-01 (daemon + control socket), SPEC-02 (CLI subcommands — the dir, the
`requireDaemon()` convention, exit 3), SPEC-27 (drafts: a spawned session defers its worktree and
harness until the first message; config picks at spawn), SPEC-29 (adapter-native lifecycle —
resume/list/**fork pending**), SPEC-33 (attachments), SPEC-35/38/39 (queue + steering).
**Blocks:** a future ensemble/`race` spec, a future CLI dashboard spec.

---

## Goal

Today the CLI can *inspect* makit and *attach* to one session. It cannot **start** work. Every
session is born in the app, which makes the terminal a read-mostly window onto a phone-first
product — and it makes the most common power-user gesture impossible to automate:

> "This session is done / stuck / out of context. Write a handoff, and continue in a fresh
> session — maybe on a different harness, maybe on a new worktree."

That gesture is today a copy-paste ritual: ask the agent for a summary, open the app, spawn a
session, pick the harness, paste the summary, re-state the goal. Every step is a command makit
already has a server handler for.

This spec makes `makit` a **first-class client** — a peer of the phone and the desktop app on the
same WSS protocol — with session lifecycle verbs (`ls`, `new`, `send`, `tail`, `wait`, `resume`,
`rm`, `handoff`), a machine contract (`--json`, exit codes), and one non-obvious consequence:

**an agent running inside a makit session can drive makit.** Every agent already has `bash`. Once
`MAKIT_SESSION_ID` is in its environment, "hand this off to codex with a summary" is something the
agent does itself, in one command, with no human in the loop.

## Why this is mostly wiring, not new machinery

Almost every capability this spec needs already exists and is reachable; what is missing is verbs,
identity, lineage, and an output contract.

| Need | What already exists | Gap |
| --- | --- | --- |
| Create a session | `session.spawn` → `manager.spawnPendingSession(projectId, agent, worktreePath, branch, configOptions)`; first `send.message` promotes the draft (names branch/worktree, applies picks) | no CLI caller; no `parentId`/`origin` |
| Read a transcript | `sub { fromSeq }` replays `session.events` (`subscription_hub.ts:55`); `EventStore.read(id, fromSeq)` | no CLI caller |
| Resume a cold session | `session.attach` + server-side re-attach on restart (`397f444`) | no CLI caller |
| End a session | `session.archive` / `session.unarchive` / `session.kill` | no CLI caller |
| Per-session env for the agent | `Manager.startOpts()` injects `MAKIT_BRIDGE_URL` / `MAKIT_BRIDGE_TOKEN` into `SpawnOpts.env` | no session identity, no CLI token |
| Worktrees / PRs / ports | `worktree.create`/`createFromPr`/`wrapUp`/`discard`, `pr.*`, `ports.*` | out of scope here, but free later |
| Fork a conversation | `SessionCapabilities.fork`, `AgentAdapter.forkSession?()`, codex `thread/fork` | **`session.fork` cmd never landed** (SPEC-29 marks it PENDING) |

## Why the CLI is not a client today (two concrete defects)

1. **Split-brain transport.** `makit sessions` speaks the **control socket** (`sessions.list`,
   NDJSON over `~/.makit/control.sock`) while `makit attach` speaks **WSS** like the app. The
   control contract is explicitly frozen at nine verbs (`daemon/protocol.ts`: *"Add verbs; do not
   repurpose"*), and it has no notion of a remote server. Growing session verbs there would
   duplicate ~15 handlers that already exist on the WSS router, in a second wire format, with a
   second set of DTO projections to drift — exactly the duplication SPEC-19 spent a spec deleting.
2. **`attach` has no identity of its own.** `cli/attach.ts` `readBearer()` reads
   `~/.makit/devices.json` and takes **`arr[0].bearer`** — the *phone's* credential. Consequences:
   revoking the phone silently kills the CLI; revoking the CLI is impossible; `makit devices` shows
   one device that is really two clients; and every future capability gate (D9) has nothing to gate
   on. It also hardcodes `127.0.0.1:7777`, so "drive my desk Mac from this devbox" cannot work.

## Decisions (locked before implementation)

| # | Decision | Why |
| --- | --- | --- |
| **D1** | **One client transport: WSS.** Every session verb in this spec is a WSS command, using the same envelope, the same DTOs and the same `hello` auth as the app. The control socket stays **lifecycle + pairing only** (`status`, `pair.*`, `devices.*`, `server.stop`, `logs.*`) and its frozen verb list is not repurposed. `sessions.list` stays for the desktop app; `makit ls` (D7) is served over WSS. | The WSS router already implements everything (`session.*`, `send.message`, `queue.*`, `worktree.*`, `pr.*`), and its snapshots are the app's own projection — so the CLI cannot drift from the app by construction. The control socket also cannot reach a *remote* makit, which D11 needs. The cost is real and accepted: a CLI session verb now needs a credential, not just filesystem access — which is what D2 makes invisible. |
| **D2** | **The CLI is its own device.** One additive control verb, `cli.grant`, returns a bearer for a device labelled `cli@<hostname>` with `caps: ["client"]`, minted on first use and cached at `~/.makit/cli.json` (mode `0600`). `readBearer()`'s `devices.json[0]` hack is deleted. `PairedDevice` gains `caps?: DeviceCap[]`; **absent means full**, so every already-paired phone keeps working. | Fixes all four defects in §2 at once: revocation becomes per-client, `makit devices` tells the truth, and there is a subject to attach capabilities to. Minting over the **unix socket** (not a pair token) is the right trust boundary: a process that can write `~/.makit/control.sock` is already the local user, and demanding a QR scan for a local terminal would be theatre. |
| **D3** | **The agent's identity comes from its environment, and it is scoped.** `startOpts()` gains `MAKIT_SESSION_ID`, `MAKIT_PROJECT_ID`, `MAKIT_WORKTREE`, `MAKIT_SPAWN_DEPTH`, and `MAKIT_CLI_TOKEN` — a **per-session** bearer with `caps: ["spawn","send","read"]` that is revoked when the session ends. The CLI prefers `MAKIT_CLI_TOKEN` over `~/.makit/cli.json` when present. | This is the whole unlock: `makit handoff --to codex` with zero positional arguments, because the CLI knows who "I" am. It must **not** reuse the bridge token: `bridge.ts` mints **one** token per server process and takes `sessionId` from the request **body, unverified** — so it can authenticate "some agent" but never authorize "spawn as *my* child". The bridge is the connector channel (`/uicall`, `/usage`); making it a client channel would widen a global secret. A per-session token dies with the session, which also makes D9's counter attributable. |
| **D4** | **`makit new` composes existing commands; `session.spawn` gains no prompt.** `new` = `session.spawn` (optionally after `worktree.create`) → `send.message`. `session.spawn` gains only `parentId?`, `handoffReason?` and `origin?`. | The draft contract is load-bearing: a spawned session is `pending` and the **first substantive message** is what names the branch/worktree and applies the pre-spawn config picks (`manager.ts` promotion path). An `initialPrompt` parameter would be a second launch path through that same promotion logic, for zero gain — the client can just send the message. |
| **D5** | **Handoff is a manifest plus a new session. The transcript is never replayed into the new agent.** `makit handoff` (a) resolves a manifest, (b) spawns with `parentId` + `handoffReason`, (c) sends the rendered manifest as the first message. `--carry last:N` appends a rendered slice of the **event log**, read over `sub { fromSeq }` — as *quoted context in a message*, not as agent state. | Cross-harness replay is not a thing: a codex thread cannot ingest a pi transcript, and the transports that *can* replay have a primitive for it (`session/load`) which is **resume**, a different feature. A message is the one interchange format every harness accepts. Reading via `sub` rather than a new `session.transcript` command reuses a path the app exercises on every subscribe. |
| **D6** | **"Fork" is two operations and the CLI names them separately.** `makit fork <id>` is the **adapter-native** fork (SPEC-29's pending `session.fork` → `forkSession()`, gated on `capabilities.fork`; codex `thread/fork` today) and fails with a precise message where unsupported (*"pi cannot fork: pi-acp advertises no `session/fork` — use `makit handoff` instead"*). `makit handoff` is the **makit-level** fork: cross-harness, manifest-carried, no native support needed. | Collapsing them into one verb would mean either lying about fidelity (a "fork" that is a summary) or shipping a verb that works on one of three harnesses. Naming them apart also lets P1 ship the workflow the user actually has, while `session.fork` lands as the honest completion of SPEC-29's pending item. |
| **D7** | **Output contract: human by default, `--json` = NDJSON of the wire, unmodified.** Stream commands emit one `SessionEvent` per line exactly as received; list commands emit the DTO array as it arrives on `sessions.snapshot`. No third projection, no reshaped fields, no `--format` zoo. Human rendering stays in `cli/render.ts`. | A bespoke CLI JSON schema is a second protocol projection that drifts from the app's the first time an event kind is added (SPEC-19's lesson; SPEC-45's D-notes make the same argument about second mechanisms). "The wire, one object per line" is also the format `jq` wants. |
| **D8** | **Exit codes are the automation contract**, derived from `SessionStatus`: `0` idle/turn complete · `10` `awaiting-approval` · `11` `awaiting-input` · `20` `error` · `21` `exited` · `3` daemon not running (SPEC-02's convention) · `4` credential/auth · `2` usage. `makit wait <id> [--for idle\|approval\|input\|any] [--timeout]` blocks and exits accordingly. | Without distinct codes, a git hook or CI job cannot tell "the agent finished" from "the agent is blocked on you" — and an agent shelling out to `makit ask … --wait` would hang forever on an approval prompt it cannot see. This is what makes the CLI scriptable rather than merely usable. |
| **D9** | **Spawn depth and fan-out are bounded, server-side.** A `session.spawn` carrying `parentId` from a `spawn`-capped credential is refused past `MAKIT_SPAWN_DEPTH >= 3` or more than `N` live children per parent (default 4), with a clear error. The env var is advisory for display; the **server** derives depth from lineage (D10). | D3 makes agents able to spawn agents; a confused loop then spawns unbounded agent processes with real money attached, and the phone becomes an unusable list of ghosts. The bound must live where the lineage does — a client-side check is a suggestion. |
| **D10** | **Lineage is protocol data, not CLI bookkeeping.** `SessionDTO` gains `parentId?`, `handoffReason?`, `origin?: "app" \| "cli" \| "agent"`, persisted on `SessionMeta`. `makit tree` is a projection of those fields, and the app can caption "handed off from …". | If lineage lived only in `~/.makit`, the phone would show mystery sessions appearing with no explanation, and D9 would have nothing to count. It is also the minimum the app needs later to draw the chain without another spec changing the wire. |
| **D11** | **Remote (`makit ctx` / `makit login`) is P3, and pins the same fingerprint the app pins.** `~/.makit/contexts.json`: named `{host, port, fingerprint, bearer}`; `makit login <makit://…>` consumes the URL `makit qr --url-only` already prints. Until then the CLI targets loopback, with `--host`/`--port` as today. | The workflow this spec exists for is local (the agent and the CLI run on the server host). Remote needs a pairing story for a device with no camera — a paste-the-URL flow, capability defaults, and cert pinning outside the app's pinning code. Real work, separable, and no P1 verb blocks on it. |
| **D12** | **No TUI, no `race`, no `fleet`.** `makit attach` stays the line-oriented readline client it is. | SPEC-02 already put a long-running TUI out of scope, and ensemble/fleet orchestration is composition *on top of* this verb set — it should be specced once these verbs are real, not designed against imagined ones. |
| **D13** | **A prompt from an agent-spawned session is routed up the lineage, then to everyone — it is never auto-approved.** `askDevice` stops filtering on `subscribed.has(sessionId)` and takes an **audience resolver**: (1) the session's own subscribers; else (2) the subscribers of the nearest ancestor via `parentId` (walking up, bounded by D9's depth); else (3) every authed client; then (4) today's `onUndeliverable` wake push. Applies identically to **both** kinds of `srv.request` — a tool permission (`awaiting-approval`) and an elicitation, i.e. a real question to the human (`awaiting-input`). The default policy stays `ask-on-risky` (`session.ts:212`); `--yolo` is opt-in **per handoff**. | Today's filter assumes every session was born on a screen, which is exactly the assumption D3 breaks: nobody has an agent-spawned session open, so `sent === 0` and the question is either pushed as a context-free buzz or **rejected outright** ("no subscribed clients to ask") — a handoff dead on arrival, discovered twenty minutes later. Routing up the lineage matches who owns the consequence: you asked for the handoff, so its questions are yours. Auto-approving instead was considered and rejected — it silently hands unsupervised shell access to an agent nobody watched, in a worktree that may hold credentials, and it fixes *only* permissions, leaving elicitation (which no policy can answer) still undeliverable. One routing rule covers both request kinds; two mechanisms would not. |
| **D14** | **A prompt is self-describing.** Because step (3) can deliver to a client that has never seen this session, the `srv.request` must carry enough for the app to caption it — session title, harness, and handoff origin (D10's `parentId`/`handoffReason`) — not just the question text. | Step (3) is what makes D13 total, and an uncaptioned "Allow `rm -rf build`?" for a session the user never opened is worse than no prompt: it trains the user to answer without reading. Attribution is what makes the fallback tolerable instead of the reason notifications get switched off. |
| **D15** | **`makit new` creates a worktree — always, not conditionally on `cwd`.** The CLI calls `worktree.create` and passes the resulting `worktreePath` + `branch` to `session.spawn`. With `-m`, the message seeds `branchName` (`slugifyBranch` + `uniqueBranch` already handle safety and collisions), so `makit new -m "fix the migration"` lands on `fix-the-migration` instead of `worktree-a1b2c3`; without `-m` the auto name stands, as in the app. `--here` is the explicit opt-out (run in `cwd`'s tree), and a non-git or unborn-HEAD repo degrades to the repo dir on its own (`createWorktree` returns `{path: repoPath, branch: null}`). **`makit handoff` is the opposite: it inherits the parent's `worktreePath` and branch**, and takes a fresh tree only when asked (`--worktree` / `--branch`). | Session-owns-a-worktree is the invariant the rest of makit is built on — tab groups are keyed by worktree (SPEC-30), ports are attributed per branch (SPEC-41/42), and SPEC-38's *Wrap up* means "remove the worktree, delete the branch, fast-forward the base". A CLI that dropped agents into the user's checkout would mint sessions that cannot be wrapped up, whose ports collide, and whose diff is tangled with the user's own uncommitted edits. Rejected the cwd-aware reading ("adopt the worktree I'm standing in") because it makes one command behave two ways depending on invisible state, and `--here` says it explicitly instead. Handoff inverts the default because **continuity is the entire point**: the manifest's `file:line` references and, usually, uncommitted work live in the parent's tree — a fresh tree off the default branch would strand exactly what was being handed over. |
| **D16** | **A handoff leaves the parent running. Sessions may share a worktree, and nothing guards against it.** No archive-the-parent default, no "turn still running" refusal, no co-tenancy warning. `makit ls` shows each session's branch/worktree so the sharing is visible, and that is the whole of the mitigation. | Parallel agents in one tree is a *feature* of the terminal workflow, not an accident to be prevented — the parent is often still finishing something useful, and a handoff is "also work on this", not always "stop". The one hazard that would have justified a guard is already handled: `removeWorktree` reconciles **every** session bound to the tree (`manager.ts:852`, live → archive, never kill), so SPEC-38's *Wrap up* cannot delete a tree out from under a co-tenant. Accepted and unmitigated: git index contention and interleaved commits (identical to the risk a human already takes editing while an agent works), two agents editing one file with no merge boundary, and — a real reporting gap — SPEC-41/42 attributes a port to a **worktree/branch**, so with two sessions in one tree the ports view cannot name which session opened it. |

## The verb grammar

Every row is a thin client of an existing or (†) new WSS command.

| Verb | Wire | Phase |
| --- | --- | --- |
| `makit ls [--archived] [--project P] [--json]` | `sessions.snapshot` · `session.listArchived` | P1 |
| `makit new [-m MSG] [--agent A] [--project P] [--here \| --branch B [--base R]] [--config k=v]... [--json]` | `worktree.create` (default, D15) + `session.spawn`† + `send.message` | P1 |
| `makit send <id> -m MSG [--attach FILE]...` | `send.message` (+ `POST /media`) | P1 |
| `makit tail <id> [-f] [--since SEQ] [--json]` | `sub { fromSeq }` | P1 |
| `makit wait <id> [--for …] [--timeout S]` | `sub` + `session.status` | P1 |
| `makit run …` (= `new` + `wait` + print) | composed | P1 |
| `makit handoff [--to A] [--carry …] [--file M \| -] [--goal …] [--next …] [--worktree]` | `session.spawn`† (inherits the parent's tree, D15) + `send.message` | P1 |
| `makit resume <id>` | `session.attach` | P1 |
| `makit rm <id> [--kill]` (default: archive) | `session.archive` · `session.kill` | P1 |
| `makit attach [<id>]` (re-homed on D2's credential) | existing | P1 |
| `makit ask <id> MSG --wait` | `send.message` + `wait` + last `agent.message` | P2 |
| `makit approve <id> [--deny]` · `makit answer <id> TEXT` | `srv.response` | P2 |
| `makit fork <id> [--agent A]` | `session.fork`† (completes SPEC-29) | P2 |
| `makit log <id>` · `makit tree` | event log · lineage (D10) | P2 |
| `makit ctx …` · `makit login URL` · `makit qr --session <id>` | contexts (D11) | P3 |

### The handoff manifest

```jsonc
// resolved from --file, stdin (`-`), or flags; written by the OUTGOING agent
{
  "goal":    "Make the migration idempotent",
  "done":    ["schema diff written", "test/migrate.test.ts covers the up path"],
  "next":    ["down path is unimplemented", "then run the full suite"],
  "files":   ["server/src/manager.ts:1361", "test/migrate.test.ts:88"],
  "gotchas": ["resumeSessionPath is legacy; use resumeAgentSessionId"],
  "openQuestions": ["do we need a lock during the backfill?"]
}
```

Rendered to a deterministic markdown first message (fixed section order, missing sections omitted).
`--carry last:N` appends a fenced transcript excerpt. Unknown keys are dropped, not rejected — the
producer is an LLM and a rejected handoff loses the context it was built from.

## Phasing

- **P0 — foundation, no new user-facing verbs.** D1's shared WSS client module (`cli/client.ts`:
  connect, hello, cmd/ack correlation, snapshot cache, clean teardown), D2's credential + `caps`,
  D7's output contract and D8's exit codes. `makit sessions` becomes `makit ls` over WSS
  (`sessions` kept as a deprecated alias for one release).
- **P1 — the handoff workflow.** D3 (env identity), D4 (`new`), D5 (`handoff`), D9 (depth guard),
  D10 (lineage on the wire + persisted), **D13 (prompt routing up the lineage) + D14 (captioned
  prompts)** — both P1, because D3 is precisely what strands a prompt, plus `send`, `tail`, `wait`,
  `run`, `resume`, `rm`, and `attach` re-homed on the new credential. **This is the slice that
  replaces the copy-paste ritual.**
- **P2 — the terminal as a full peer.** `session.fork` (SPEC-29's pending item), `approve`/`answer`
  (unblocking an agent-spawned session from the terminal), `ask --wait` (cross-harness delegation),
  `log`/`tree`, and the app-side "handed off from …" caption on D10's fields.
- **P3 — remote.** D11 contexts/login, and `makit qr --session <id>` to continue a terminal session
  on the phone.

## Non-goals

- **Any second storage.** No CLI-side transcript cache or session DB; the event store and the
  session snapshots are the only sources.
- **Summarising in the CLI.** The manifest is written by the agent that has the context. The CLI
  renders and transports it; it never calls a model.
- **Repurposing frozen control verbs** (D1), or extending the loopback bridge into a client channel
  (D3).
- **Ensemble/`race`, `fleet` files, a TUI dashboard, `diff`/`cherry-pick` between sessions** — all
  deliberately deferred; they compose on this verb set (D12).
- **Mirror / World-D behaviour** (`makit-mirror`), and any change to how the app spawns sessions.

## Acceptance criteria

**P0**
- [ ] `makit ls --json` emits exactly the `SessionDTO` array from `sessions.snapshot` (byte-compared
      against the frame in a stub-server test), and nothing else on stdout.
- [ ] First run of any client verb mints `~/.makit/cli.json` (mode `0600`) via `cli.grant`;
      `makit devices` then lists a `cli@<host>` device distinct from the phone. Revoking it makes
      the next verb exit `4`; revoking the **phone** leaves the CLI working.
- [ ] No CLI code path reads `devices.json` (asserted by a grep test — this is the §2 defect).
- [ ] Daemon down → SPEC-02's message and exit `3`, no stack trace, for every verb.

**P1**
- [ ] `makit new --agent codex -m "hello"` creates a session that appears in the **app's**
      `sessions.snapshot` with `origin: "cli"`, promotes out of `pending`, and the reply streams to
      `makit tail -f` and the app simultaneously.
- [ ] An agent shell-out inside a makit session runs `makit handoff --to codex --carry last:5
      --goal "…"` with **no session/project arguments** and the new session's first message contains
      the rendered manifest + a 5-event excerpt; its `parentId` is the calling session.
- [ ] `makit wait <id>` exits `0` on turn end, `10` when the agent asks for approval, `11` on
      ask-user, `20` on error — proven against `test/e2e-server.ts --mode stub` (keyless).
- [ ] A spawn chain refuses at depth 3 and at the 5th live child, with a message naming the limit;
      the refusal is server-side (proven by a direct WSS `session.spawn` with a forged shallow
      `MAKIT_SPAWN_DEPTH`).
- [ ] **D15**: `makit new -m "fix the migration"` creates a worktree on a branch named from the
      message (not `worktree-<uuid>`), and the session's `worktreePath` is that tree, never the repo
      dir. `--here` runs in `cwd`. A non-git project and an unborn HEAD both land in the repo dir
      without an error.
- [ ] **D15 inverse**: a `makit handoff` child reports the **parent's** `worktreePath` and branch, so
      the parent's uncommitted work is visible to it; `--worktree` opts into a fresh tree.
- [ ] **D16**: a handoff leaves the parent `idle`/`running` (not archived), both sessions report the
      **same** `worktreePath`, and *Wrap up* on that tree archives **both** — a regression lock on
      `removeWorktree`'s existing all-sessions reconciliation, which this decision now depends on.
- [ ] `MAKIT_CLI_TOKEN` is rejected once its session ends (exit `4`).
- [ ] **D13 routing**, proven rung by rung against the stub adapter: a prompt from a handoff child
      reaches a client that has only the **parent** open; with the parent closed too it reaches every
      authed client; with no client at all it still takes the wake-push path and stays pending. No
      prompt is ever auto-answered, and an elicitation (`awaiting-input`) routes identically to a
      permission (`awaiting-approval`).
- [ ] The lineage walk terminates on a cycle and on a missing/archived ancestor (unit test with a
      forged `parentId` loop).
- [ ] **D14**: the `srv.request` envelope carries session title, agent and `handoffReason`, and the
      app captions a prompt for a session it has never subscribed to.
- [ ] Manifest rendering is deterministic and total: golden test over full/partial/empty/unknown-key
      inputs, no throw.
- [ ] `pnpm test` green, `pnpm typecheck` clean; app-side additive DTO fields keep
      `flutter analyze --fatal-infos` clean.

**P2/P3** — criteria written with those phases (kept out here so P1 can ship).

## Open questions

1. **Does the parent get a `session.meta` note ("handed off to …")?** Not a lifecycle question any
   more (D16 settled that), purely discoverability: the note makes the chain visible in the app
   without opening the child, at the cost of a new payload field. D10's `parentId` already carries
   the fact — this is only about surfacing it from the parent's side.
2. **Where does the manifest live on disk?** `<worktree>/.makit/handoff/*.json` (git-excluded, like
   SPEC-33's materialised attachments, and visible to both agents) vs `~/.makit/handoff/`
   (server-scoped, survives worktree removal).
3. **Where are `caps` enforced?** In `auth_gate.ts` as a per-connection allowlist (one place, coarse)
   or per command handler (precise, spread out).
4. **`makit sessions` alias lifetime** — one release, or keep it permanently since it is in SPEC-02's
   frozen-ish surface and possibly in users' scripts.

## Current-state anchors (real code this spec builds on)

- CLI: `server/src/cli/{attach,sessions,qr,devices,status,render,require-daemon}.ts`; dispatch in
  `server/src/index.ts` `main()` (`KNOWN` set).
- Control plane: `server/src/daemon/{protocol,control-client,control-server,service}.ts`
  (`CONTROL_VERBS`, frozen).
- WSS: `server/src/ws/{client,auth_gate,command_router,subscription_hub}.ts` +
  `ws/commands/{session,worktree,repo,queue,ports,github,metrics}.ts`.
- Spawn/promotion/env: `server/src/manager.ts` (`spawnPendingSession`, `applyConfigPicks`,
  `startOpts`, `createSession`, re-attach).
- Wire types: `server/src/protocol.ts` (`EventKind`, `SessionEvent`, `SessionDTO`, `SessionStatus`).
- Persistence: `server/src/storage/{event_store,sqlite_event_store}.ts` (`read(id, fromSeq)`,
  `SessionMeta`); `server/src/pairing/registry.ts` (`PairedDevice`).
- Bridge (explicitly *not* the client channel): `server/src/bridge.ts` (one token per process,
  `sessionId` from the body).
- Keyless verification loop: `pnpm exec tsx test/e2e-server.ts --mode stub --project <path>`
  (port `9787`, seeded bearer `e2e-token`, in-process `StubAdapter`).
