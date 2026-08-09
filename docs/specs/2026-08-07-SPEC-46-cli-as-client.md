# SPEC-46 — The CLI is a client: sessions from the terminal, handoff as a command

**Status:** Draft **rev 3** (dual codex review applied in rev 2; rev 3 closes the D3 spike — see §Review
findings applied) · **Priority:** P1 · **Branch:** `feat/cli-client`
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
| Read a transcript | `sub { fromSeq }` replays `session.events` (`subscription_hub.ts:55`), whose getter lazily hydrates the **whole** persisted log (`session.ts:195`); `EventStore.read(id, fromSeq)` exists but `sub` does not use it | no CLI caller, and **no bounded tail** — hence D5's `session.transcript` |
| Resume a cold session | `session.attach` + server-side re-attach on restart (`397f444`) | no CLI caller |
| End a session | `session.archive` / `session.unarchive` / `session.kill` | no CLI caller |
| Per-session env for the agent | `Manager.startOpts()` injects `MAKIT_BRIDGE_URL`, `MAKIT_BRIDGE_TOKEN` **and `MAKIT_SESSION_ID`** into `SpawnOpts.env` (`manager.ts:1278`-`1284`) | project/worktree/depth fields + a scoped CLI token; **env is proven only as far as the immediate child** |
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
| **D3** | **The agent's environment carries a scoped credential — session identity is already there.** `startOpts()` **already** injects `MAKIT_SESSION_ID` (`manager.ts:1282`), so this decision adds only `MAKIT_PROJECT_ID`, `MAKIT_WORKTREE`, `MAKIT_SPAWN_DEPTH` and `MAKIT_CLI_TOKEN` — a **per-session** bearer with `caps: ["spawn","send","read"]`, minted with the session, revoked when it ends, and **re-minted on every re-attach** (`startOpts` is rebuilt at `manager.ts:1401`, so the restored session's old token must be dropped in the same step). The CLI prefers it over `~/.makit/cli.json`. | This is the unlock: `makit handoff --to codex` with zero positional arguments, because the CLI knows who "I" am. It must **not** reuse the bridge token: `bridge.ts:46`-`71` mints **one** token per server process and reads `sessionId` from the request **body, unverified** — it can authenticate "some agent" but never authorize "spawn as *my* child". A per-session token dies with the session, which is also what makes D9's counter attributable. **Rev 3 — the spike ran; D3 stands unchanged.** Rev 2 owed a spike on whether the token reaches **pi** or only `pi-acp`. It reaches pi. `pi-acp`'s `PiRpcProcess.spawn` passes `env: process.env` to the pi child (`pi-acp@0.0.32` `dist/index.js:137`-`142`), and a shim substituted at that exact spawn site via `PI_ACP_PI_COMMAND` received `MAKIT_CLI_TOKEN` and `MAKIT_SESSION_ID` intact. This is already true in production: a live pi agent under `pi-acp` has `MAKIT_SESSION_ID` in its environment today. Rev 2's premise was **wrong** — the fixed argv is not "the same seam" that drops `SpawnOpts.extensions`, because env and extensions travel by different mechanisms: extensions are argv (and `pi-acp`'s argv is hardcoded `--mode rpc --no-themes`, which `adapters/acp.ts:266`-`269` already logs as unsupported), while env is process inheritance, which argv has no bearing on. **The one real constraint the spike found:** `env: process.env` is a *snapshot taken when pi is spawned*, so an env-delivered token cannot be rotated in a running process. D3's "re-minted on every re-attach" is sound only because re-attach restarts the adapter (`manager.ts:1401` rebuilds `startOpts` → `adapter.start()` → fresh `pi-acp` → fresh pi). Any future rotation **not** accompanied by an adapter restart is impossible over env and would need the bridge-style handshake. |
| **D4** | **`makit new` composes existing commands; `session.spawn` gains no prompt.** `new` = `session.spawn` (after `worktree.create`, D15) → `send.message`. `session.spawn` gains only `parentId?`, `handoffReason?` and `origin?`. | The draft contract is load-bearing: a spawned session is `pending`, and the **first `send.message`** is what names the branch/worktree and applies the pre-spawn config picks (promotion at `manager.ts:871`-`907`; concurrent promotions collapse onto one promise at `manager.ts:938`). An `initialPrompt` parameter would be a second launch path through that same promotion logic for zero gain. **Rev 2:** rev 1 called it the first *substantive* message, which is the code **comment's** phrasing, not the behaviour — `ws/commands/session.ts:140` promotes on **any** string, `""` included (an image-only turn falls back to `IMAGE_ONLY_LABEL`). Nothing in the design depended on the word, but the CLI must not rely on a substantive-message guard that does not exist. |
| **D5** | **Handoff is a manifest plus a new session. The transcript is never replayed into the new agent.** `makit handoff` (a) resolves a manifest, (b) spawns with `parentId` + `handoffReason`, (c) sends the rendered manifest as the first message. `--carry last:N` appends a rendered slice, read through a **new bounded command `session.transcript { sessionId, limit }`** answered from the event log server-side — as *quoted context in a message*, not as agent state. | Cross-harness replay is not a thing: a codex thread cannot ingest a pi transcript, and the transports that *can* replay have a primitive for it (`session/load`) which is **resume**, a different feature. A message is the one interchange format every harness accepts. **Rev 2:** rev 1 read the slice via `sub { fromSeq }`, which cannot bound it — `sub` takes no limit, no DTO publishes a latest seq to subtract from, and `session.events` hydrates the entire persisted log before the filter runs (`subscription_hub.ts:55`, `session.ts:195`). `--carry last:5` on a long session would therefore load and ship the whole transcript to print five lines. One small server-side command is cheaper than a `latestSeq` field plus client arithmetic, and it makes the flood impossible rather than unlikely. |
| **D6** | **"Fork" is two operations and the CLI names them separately.** `makit fork <id>` is the **adapter-native** fork (SPEC-29's pending `session.fork` → `forkSession()`, gated on `capabilities.fork`; codex `thread/fork` today) and fails with a precise message where unsupported (*"pi cannot fork: pi-acp advertises no `session/fork` — use `makit handoff` instead"*). `makit handoff` is the **makit-level** fork: cross-harness, manifest-carried, no native support needed. | Collapsing them into one verb would mean either lying about fidelity (a "fork" that is a summary) or shipping a verb that works on one of three harnesses. Naming them apart also lets P1 ship the workflow the user actually has, while `session.fork` lands as the honest completion of SPEC-29's pending item. |
| **D7** | **Output contract: human by default, `--json` = NDJSON of the wire, unmodified.** Stream commands emit one `SessionEvent` per line exactly as received; list commands emit the DTO array as it arrives on `sessions.snapshot`. No third projection, no reshaped fields, no `--format` zoo. Human rendering stays in `cli/render.ts`. | A bespoke CLI JSON schema is a second protocol projection that drifts from the app's the first time an event kind is added (SPEC-19's lesson; SPEC-45's D-notes make the same argument about second mechanisms). "The wire, one object per line" is also the format `jq` wants. |
| **D8** | **Exit codes are the automation contract**, and `wait` is **edge-triggered**: `0` turn complete · `10` `awaiting-approval` · `11` `awaiting-input` · `20` a terminal `session.error` · `21` `exited` · `3` daemon not running (SPEC-02's convention) · `4` credential/auth · `2` usage. `makit wait <id> [--for idle\|approval\|input\|any] [--timeout]` records the seq it started at and requires a `running` → non-running **transition** before exiting `0`. | Without distinct codes a git hook or CI job cannot tell "the agent finished" from "the agent is blocked on you", and an agent shelling out to `makit ask … --wait` would hang forever on an approval it cannot see. **Rev 2:** rev 1 derived all of this from `SessionStatus`, which was wrong twice. (i) **Nothing emits `status: "error"`** — adapters emit a `session.error` event and then settle *idle* (`acp.ts:313`, `codex.ts:250`; `session.ts:281` only moves status on `session.status`), so `20` must key off the event. (ii) `send.message` **acks before promotion** (`ws/commands/session.ts:128`), so a composed `new + send + wait` would observe the pre-existing `idle` and exit `0` having waited for nothing. The app already solved the boundary with a running→non-running edge (`notification_policy.dart:19`); the CLI copies it rather than inventing one. |
| **D9** | **Lineage is derived from the credential, never taken from the wire — and depth/fan-out are bounded server-side.** For an agent-scoped token the parent **is** that token's session; a body `parentId` that disagrees is refused (`BadRequest`), not quietly honoured. Depth and live-child count are computed from persisted lineage (D10); refuse past depth `3` or more than `4` live children. `MAKIT_SPAWN_DEPTH` is display only. | D3 makes agents able to spawn agents; a confused loop then spawns unbounded agent processes with real money attached. **Rev 2:** rev 1 let the client supply `parentId` while the guard counted lineage — so a spawn bearer could forge shallow ancestry to escape the bound, attach a child to an unrelated session, or build a cycle, making the guard advisory. Deriving the parent from the credential also makes cycles impossible by construction, which demotes "the walk terminates on a cycle" from a live path to a unit test over hostile persisted data. |
| **D10** | **Lineage is protocol data, not CLI bookkeeping.** `SessionDTO` gains `parentId?`, `handoffReason?`, `origin?: "app" \| "cli" \| "agent"`, persisted on `SessionMeta`. `makit tree` is a projection of those fields, and the app can caption "handed off from …". | If lineage lived only in `~/.makit`, the phone would show mystery sessions appearing with no explanation, and D9 would have nothing to count. It is also the minimum the app needs later to draw the chain without another spec changing the wire. |
| **D11** | **Remote (`makit ctx` / `makit login`) is P3, and pins the same fingerprint the app pins.** `~/.makit/contexts.json`: named `{host, port, fingerprint, bearer}`; `makit login <makit://…>` consumes the URL `makit qr --url-only` already prints. Until then the CLI targets loopback, with `--host`/`--port` as today. | The workflow this spec exists for is local (the agent and the CLI run on the server host). Remote needs a pairing story for a device with no camera — a paste-the-URL flow, capability defaults, and cert pinning outside the app's pinning code. Real work, separable, and no P1 verb blocks on it. |
| **D12** | **No TUI, no `race`, no `fleet`.** `makit attach` stays the line-oriented readline client it is. | SPEC-02 already put a long-running TUI out of scope, and ensemble/fleet orchestration is composition *on top of* this verb set — it should be specced once these verbs are real, not designed against imagined ones. |
| **D13** | **A stranded prompt is routed up the lineage, then to everyone — never auto-approved — and both the pending record and the *answer* are authorized.** (a) `askDevice` takes an audience resolver: the session's own subscribers → the nearest ancestor's subscribers via `parentId` → every authed client → today's `onUndeliverable` wake push (which stays gated on `sent === 0`). (b) The resolved eligibility is **stored on the pending request**, so `replayPendingTo()` re-sends only to clients that were eligible. (c) An `srv.response` is accepted **only** from a client in that audience, and **never** from an agent-scoped token. Applies identically to a tool permission (`awaiting-approval`) and an elicitation (`awaiting-input`). Default policy stays `ask-on-risky` (`session.ts:212`); `--yolo` is opt-in per handoff **and settable only by a human credential** (`caps: ["client"]`). | Today's `subscribed.has(sessionId)` filter assumes every session was born on a screen — exactly what D3 breaks: nobody has an agent-spawned session open, so `sent === 0` and the question is either a context-free push or **rejected outright**, a handoff dead on arrival. Routing up the lineage matches who owns the consequence. Auto-approving instead was rejected: it hands unsupervised shell access to an agent nobody watched, and fixes *only* permissions, leaving elicitation undeliverable. **Rev 2:** (b) and (c) are not polish — without them the ladder is decorative. `replayPendingTo()` re-sends **every** pending request to **every** newly-authed client regardless of subscription, on both auth and `sub` (`reverse_rpc.ts:65`), and `handleResponse` takes the first answer with no check on the sender (`reverse_rpc.ts:76`). So rev 1 would have let a never-subscribed device — or the child agent's own token — approve another session's tool call. Same reason `--yolo` cannot be agent-settable: an agent granting itself broader authority is not human opt-in. |
| **D14** | **A prompt is self-describing.** Because step (3) can deliver to a client that has never seen this session, the `srv.request` must carry enough for the app to caption it — session title, harness, and handoff origin (D10's `parentId`/`handoffReason`) — not just the question text. | Step (3) is what makes D13 total, and an uncaptioned "Allow `rm -rf build`?" for a session the user never opened is worse than no prompt: it trains the user to answer without reading. Attribution is what makes the fallback tolerable instead of the reason notifications get switched off. |
| **D15** | **`makit new` creates a worktree — always, not conditionally on `cwd`.** The CLI calls `worktree.create` and passes the resulting `worktreePath` + `branch` to `session.spawn`. With `-m`, the message seeds `branchName` (`slugifyBranch` + `uniqueBranch` already handle safety and collisions), so `makit new -m "fix the migration"` lands on `fix-the-migration` instead of `worktree-a1b2c3`; without `-m` the auto name stands, as in the app. `--here` is the explicit opt-out (run in `cwd`'s tree), and a non-git or unborn-HEAD repo degrades to the repo dir on its own (`createWorktree` returns `{path: repoPath, branch: null}`). **`makit handoff` is the opposite: it inherits the parent's `worktreePath` and branch**, and takes a fresh tree only when asked (`--worktree` / `--branch`). | Session-owns-a-worktree is the invariant the rest of makit is built on — tab groups are keyed by worktree (SPEC-30), ports are attributed per branch (SPEC-41/42), and SPEC-38's *Wrap up* means "remove the worktree, delete the branch, fast-forward the base". A CLI that dropped agents into the user's checkout would mint sessions that cannot be wrapped up, whose ports collide, and whose diff is tangled with the user's own uncommitted edits. Rejected the cwd-aware reading ("adopt the worktree I'm standing in") because it makes one command behave two ways depending on invisible state, and `--here` says it explicitly instead. Handoff inverts the default because **continuity is the entire point**: the manifest's `file:line` references and, usually, uncommitted work live in the parent's tree — a fresh tree off the default branch would strand exactly what was being handed over. |
| **D16** | **A handoff leaves the parent running. Sessions may share a worktree, and nothing guards against it.** No archive-the-parent default, no "turn still running" refusal, no co-tenancy warning. `makit ls` shows each session's branch/worktree so the sharing is visible, and that is the whole of the mitigation. | Parallel agents in one tree is a *decision*, not an accident to prevent — the parent is often still finishing something useful, and a handoff is frequently "also work on this". The hazard that would have justified a guard is already handled: `removeWorktree` reconciles **every** session bound to the tree (`manager.ts:833`-`863`: live → archive, drafts killed, already-archived left alone), so SPEC-38's *Wrap up* cannot delete a tree from under a co-tenant; the app's worktree groups and `repo_service.ts`'s `sessionIds: string[]` already model many sessions per tree. Accepted and unmitigated: git index contention and interleaved commits (the risk a human already takes editing while an agent works), and two agents editing one file with no merge boundary. **Rev 2 correction:** rev 1 also claimed the ports view could not name which co-tenant opened a port. It can — `PortDTO.sessionId` is derived by walking the agent's own process tree (`protocol.ts:301`, `ports/attribute.ts:158`), so a port opened under session A stays attributed to A. |
| **D17** | **`caps` are enforced once, at the connection's principal — and event fanout is gated on it too.** `AuthGate` returns a principal (`{deviceId, label, caps, sessionId?}`) instead of `{id, label}`; `WsClient` carries it; the router checks a per-command capability map before dispatch, and `srv.response` is checked against D13(c). A principal with no `caps` — every already-paired phone — is full access. **Rev 3:** a command map alone is not sufficient, because **`fanout()` is not a command**: it sends every session event to **every authed client**, ignoring subscription entirely (`subscription_hub.ts:76`-`84`, whose `_sessionId` parameter is unused by design — "subscription is NOT required to receive live events"). So an agent-scoped principal that connects at all would receive the transcripts of every session on the machine, including its parent's and unrelated users' work. A session-scoped principal (`sessionId` set) therefore receives fanout **only** for its own session and its descendants; a `client` principal keeps today's auto-mirror behaviour unchanged. | Rev 1 left this as an open question, and the review was right that doing so makes D2, D3, D9 and D13 rest on an enforcement point that **does not exist**: `AuthGate` returns `{id,label}` (`auth_gate.ts:21`), `WsClient` stores no principal (`client.ts:15`), and every authed socket may dispatch every command (`server.ts:650`). One coarse place is the correct trade: a per-handler check would spread the rule across every command file and still miss `srv.response`, which is not a command at all — **and would equally miss `fanout`, which is the rev-3 addition.** The two non-command paths (`srv.response` in, events out) are exactly where a per-handler design leaks, which is the argument for a principal on the connection rather than checks at the leaves. |

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
| `makit handoff [--to A] [--carry …] [--file M \| -] [--goal …] [--next …] [--worktree]` | `session.spawn`† (inherits the parent's tree, D15) + `session.transcript`† (for `--carry`) + `send.message` | P1 |
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
  **D17's principal + router enforcement** (without it D2's caps are decoration), D7's output
  contract and D8's exit codes. `makit sessions` becomes `makit ls` over WSS (`sessions` kept as a
  deprecated alias for one release).
- **P1 — the handoff workflow.** D3 (env identity), D4 (`new`), D5 (`handoff`), D9 (depth guard),
  D10 (lineage on the wire + persisted, **including the SQLite migration and the hand-maintained
  Flutter DTO**), **D13 (routing + pending-eligibility + response authorization) and D14 (captioned
  prompts, which is app work in P1 — rev 1's phasing wrongly implied otherwise)** — both P1, because
  D3 is precisely what strands a prompt, plus `send`, `tail`, `wait`, `run`, `resume`, `rm`, and
  `attach` re-homed on the new credential. **This is the slice that replaces the copy-paste
  ritual.**
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

**Status: P0 + P1 landed** on `feat/cli-client` (T1–T21). Every box below is backed by a test in the
suite — `pnpm test` 1288 green, `pnpm typecheck` clean, `flutter analyze --fatal-infos` clean — and the
composed verbs were additionally driven end-to-end against the keyless stub loop
(`test/e2e-server.ts --mode stub`, which now also serves a control socket so the CLI can reach it):
`new` → `tail` → `run` returning `0`, `10` (approval gate) and `20` (`FAIL_TURN`), and a `handoff`
whose child received the rendered manifest plus a fenced 3-event excerpt on the parent's own branch.

Three criteria are proven narrower than their wording, and are recorded here rather than ticked
silently:

1. **"the reply streams to `makit tail -f` and the app simultaneously"** — the `tail` half is proven
   live, and `makit ls` reads the same `sessions.snapshot` projection the app renders, so the DTO path
   is shared by construction. A *running Flutter client* observing the same stream was not exercised.
2. **The handoff `parentId` derived from an agent credential** is unit-proven at the `session.spawn`
   handler (agent token → its own session; a body `parentId` naming another → `BadRequest`). The live
   run used the CLI's own credential, because a session token lives only in memory (C2) and cannot be
   read from outside the agent it was minted for.
3. **D14 captions** cover the permission dialog and the `input` elicitation. `askUserQuestion` renders
   *inline in the transcript*, so at rung 3 it lands in a session view the user is not looking at —
   there is no dialog to caption. **Open question for P2:** whether a stranded inline elicitation
   needs a surface of its own, or should be promoted to a dialog when the client never subscribed.

**P0**
- [x] `makit ls --json` emits exactly the `SessionDTO` array from `sessions.snapshot` (byte-compared
      against the frame in a stub-server test), and nothing else on stdout.
- [x] First run of any client verb mints `~/.makit/cli.json` (mode `0600`) via `cli.grant`;
      `makit devices` then lists a `cli@<host>` device distinct from the phone. Revoking it makes
      the next verb exit `4`; revoking the **phone** leaves the CLI working.
- [x] No CLI code path reads `devices.json` (asserted by a grep test — this is the §2 defect).
- [x] **D17**: a principal with `caps: ["client"]` is refused a command outside its map, a principal with no `caps` (an existing phone) is unaffected, and the refusal is at the router — not inside a handler.
- [x] **D17 fanout (rev 3)**: a session-scoped principal receives `session.*` events for its own
      session only — a second, unrelated session's events do **not** reach it. Regression lock on
      `fanout`'s deliberate subscription-blind auto-mirror, which is correct for a phone and a leak
      for an agent token.
- [x] **D17 completeness**: a test enumerates every kind registered on the `CommandRouter` and fails
      if any kind is absent from the capability map — so a command added later cannot become
      agent-reachable by omission. (`CommandRouter` has no way to list kinds today; the test needs
      one, which is the smallest possible addition.)
- [x] Daemon down → SPEC-02's message and exit `3`, no stack trace, for every verb.

**P1**
- [x] `makit new --agent codex -m "hello"` creates a session that appears in the **app's**
      `sessions.snapshot` with `origin: "cli"`, promotes out of `pending`, and the reply streams to
      `makit tail -f` and the app simultaneously.
- [x] An agent shell-out inside a makit session runs `makit handoff --to codex --carry last:5
      --goal "…"` with **no session/project arguments**; the new session's first message contains the
      rendered manifest + a 5-event excerpt fetched via `session.transcript { limit: 5 }`, and its
      `parentId` is the calling session **as derived from the credential** (D9).
- [x] `makit wait <id>` exits `0` only after a `running` → non-running **edge** — a `wait` started
      while the session is already `idle` must not exit `0` until a turn has actually run and
      finished. `10`/`11`/`20` require the stub to **emit** `awaiting-approval`, `awaiting-input` and
      a terminal `session.error`; it emits none of the three today (`adapters/stub.ts` has no
      `awaiting`), so extending the stub is part of this criterion, not an assumption of it.
- [x] A spawn chain refuses at depth 3 and at the 5th live child, with a message naming the limit.
      Proven **server-side against a hostile client**: a forged shallow `MAKIT_SPAWN_DEPTH` is
      ignored, and a `session.spawn` from an agent token carrying a `parentId` other than its own
      session is refused (`BadRequest`) rather than honoured.
- [x] **D15**: `makit new -m "fix the migration"` creates a worktree on a branch named from the
      message (not `worktree-<uuid>`), and the session's `worktreePath` is that tree, never the repo
      dir. `--here` runs in `cwd`. A non-git project and an unborn HEAD both land in the repo dir
      without an error.
- [x] **D15 inverse**: a `makit handoff` child reports the **parent's** `worktreePath` and branch, so
      the parent's uncommitted work is visible to it; `--worktree` opts into a fresh tree.
- [x] **D16**: a handoff leaves the parent `idle`/`running` (not archived), both sessions report the
      **same** `worktreePath`, and *Wrap up* on that tree archives **both** — a regression lock on
      `removeWorktree`'s existing all-sessions reconciliation, which this decision now depends on.
- [x] `MAKIT_CLI_TOKEN` is rejected once its session ends (exit `4`), cannot name a **different**
      session while it lives, and a re-attach mints a new one while revoking the old (D3).
- [x] ~~**Spike, not a unit test**: `MAKIT_CLI_TOKEN` actually reaches **pi**~~ — **done (rev 3), D3
      unchanged.** Proven three ways: `env: process.env` in `pi-acp`'s spawn, a shim at that spawn
      site receiving the token, and a live pi agent that has `MAKIT_SESSION_ID` today. Replaced by a
      narrower criterion: **token rotation requires an adapter restart** — assert that a re-attach
      mints a new token *and* starts a new agent process, because an env-delivered token cannot be
      changed in a running pi.
- [x] **`SessionMeta` migration**: an existing `~/.makit` database gains the lineage columns in place
      (explicit `ALTER TABLE` in the migration block, `sqlite_event_store.ts:104`-`164`), a session
      written before the migration rehydrates with `parentId: undefined`, and the **hand-maintained**
      Flutter `Session` DTO parses the new fields (`app/lib/store/models.dart:1120`).
- [x] **D13 routing**, proven rung by rung against the stub adapter: a prompt from a handoff child
      reaches a client that has only the **parent** open; with the parent closed too it reaches every
      authed client; with no client at all it still takes the wake-push path and stays pending. No
      prompt is ever auto-answered, and an elicitation (`awaiting-input`) routes identically to a
      permission (`awaiting-approval`).
- [x] **D13(b)**: a client that authenticates *after* the prompt was raised and was **not** in its
      audience receives nothing from `replayPendingTo()` — the regression this decision depends on,
      since today that function ignores eligibility entirely.
- [x] **D13(c)**: an `srv.response` from a client outside the audience, and one from an agent-scoped
      token, are both rejected and do **not** resolve the pending request; `--yolo` from an
      agent-scoped credential is refused.
- [x] The lineage walk terminates on a cycle and on a missing/archived ancestor (unit test with a
      forged `parentId` loop).
- [x] **D14**: the `srv.request` envelope carries session title, agent and `handoffReason`, and the
      app captions a prompt for a session it has never subscribed to.
- [x] Manifest rendering is deterministic and total: golden test over full/partial/empty/unknown-key
      inputs, no throw.
- [x] `pnpm test` green, `pnpm typecheck` clean; app-side additive DTO fields keep
      `flutter analyze --fatal-infos` clean.

**P2/P3** — criteria written with those phases (kept out here so P1 can ship).

## Review findings applied (rev 2)
Rev 1 was reviewed by two independent `codex exec` passes — one verifying every claim against the
code, one judging scope and testability against `AGENTS.md`. Verdicts: **FLAWED** and **RESCOPE**.
Every falsification below was re-checked by the author against the code before being accepted.

### Accepted — claims the code contradicted

| Rev 1 said | Reality | Where it landed |
| --- | --- | --- |
| `startOpts()` has no session identity | `MAKIT_SESSION_ID` is already injected (`manager.ts:1282`) | D3 shrunk to project/worktree/depth/token |
| exit `20` derives from `SessionStatus` | **No producer of `status: "error"` exists**; adapters emit `session.error` then settle idle | D8 keys `20` off the event |
| `--carry last:N` reads via `sub { fromSeq }` | `sub` takes no limit, no DTO exposes a latest seq, and `session.events` hydrates the whole log first | D5 adds bounded `session.transcript` |
| the ports view cannot attribute a co-tenant's port | `PortDTO.sessionId` is derived from the agent's process tree (`ports/attribute.ts:158`) | D16's risk list corrected |
| promotion needs the first *substantive* message | Any string promotes, `""` included (`ws/commands/session.ts:140`) — that word is a code comment's, not the behaviour's | D4 reworded |
| the stub proves exit `10`/`11`/`20` | The stub emits no `awaiting-*` and only `session.error` | the criterion now includes extending the stub |

### Accepted — design defects

1. **`parentId` from the wire made D9 advisory** — forgeable shallow ancestry, foreign parents,
   cycles. Now derived from the credential (D9).
2. **`replayPendingTo()` and `handleResponse` defeated D13** — every pending prompt is re-sent to
   every newly-authed client, and the first answer wins with no sender check (`reverse_rpc.ts:65`,
   `:76`). Eligibility now lives on the pending record and the response is authorized (D13 b/c).
3. **`wait` had no turn boundary** — `send.message` acks before promotion, so `new + send + wait`
   could exit `0` having waited for nothing. Now edge-triggered (D8).
4. **`caps` enforcement was an open question underneath four decisions** — there is no principal on
   the connection today. Now **D17**, in P0.
5. **Omissions**: the `SessionMeta` SQLite migration, the hand-maintained Flutter DTO, and the fact
   that env delivery is proven only to `pi-acp`, not to its child `pi` (now a P1 spike).
6. **Phasing incoherence**: D14 required app work while Phasing deferred app captions to P2. P1 now
   states the app work it owns.

### Rejected, with reasons

- **"Rescope P1 to handoff alone; cut `ls`/`new`/`send`/`tail`/`wait`/`resume`/`rm`/`fork`."** The
  reviewer did not have the originating request, which named creating, forking, resuming and listing
  sessions explicitly. YAGNI governs *speculative* surface, not requested surface. Also practical: a
  handoff you cannot `ls` or `tail` sends the user back to the app — the ritual this spec deletes.
- **"Cut the manifest schema; prose is equivalent for an LLM→LLM handoff."** A fair argument,
  rejected on the requester's call: the structure is the point of the feature, and a fixed section
  order is what makes a handoff skimmable by a human reading the child's first message.
- **"Cut `--carry` from P1."** Kept — but its mechanism was broken and is now fixed (D5). Cutting it
  would have hidden a protocol gap instead of closing it.
- **"`--yolo` cannot be meaningful opt-in."** Half accepted: the flag stays, but only a human
  credential may set it (D13). An agent granting itself authority was the real defect.
- **"D12 is not a decision."** Correct, and kept anyway: an explicit non-goal in the decision table
  is cheaper to point at than one buried in prose.

## Review findings applied (rev 3)

Rev 3 is not a review pass; it is the result of **running rev 2's owed spike** and of re-reading the
fanout path while gathering anchors for the implementation plan.

| Rev 2 said | Reality | Where it landed |
| --- | --- | --- |
| the token may not reach pi, because `pi-acp`'s fixed argv is "the same seam" that drops `SpawnOpts.extensions` | It reaches pi. `pi-acp` spawns pi with `env: process.env` (`dist/index.js:137`); env travels by **inheritance**, extensions by **argv** — different seams. A live pi agent has `MAKIT_SESSION_ID` today | D3 unchanged; spike criterion closed |
| — (not considered) | `fanout()` ignores subscription and sends **every** session's events to **every** authed client (`subscription_hub.ts:76`) — so a router-only capability check would let an agent-scoped token read the whole machine's transcripts | D17 gained fanout gating + two criteria |
| — (not considered) | `env: process.env` is a spawn-time snapshot, so an env-delivered token **cannot** be rotated in a running process | D3 records the constraint; the criterion now asserts rotation implies an adapter restart |

A methodology note worth keeping, because it nearly inverted D3: `ps -E` **cannot** read another
process's environment on macOS (SIP), and returns the argv silently rather than erroring. The first
spike run "proved" the token was absent; a control process with a known marker showed the tool, not
the token, was missing. Any future env-delivery question should use a shim at the spawn site.

## Open questions

1. **Does the parent get a `session.meta` note ("handed off to …")?** Not a lifecycle question any
   more (D16 settled that), purely discoverability: the note makes the chain visible in the app
   without opening the child, at the cost of a new payload field. D10's `parentId` already carries
   the fact — this is only about surfacing it from the parent's side.
2. **Where does the manifest live on disk?** `<worktree>/.makit/handoff/*.json` (git-excluded, like
   SPEC-33's materialised attachments, and visible to both agents) vs `~/.makit/handoff/`
   (server-scoped, survives worktree removal).
3. **`makit sessions` alias lifetime** — one release, or keep it permanently since it is in SPEC-02's
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
