---
name: "spike-agent-protocol-raw-jsonrpc"
description: "Settle a question about codex app-server or an ACP agent's real wire behavior by driving the binary directly over stdio JSON-RPC, before changing makit's adapters."
---
## When to Use
Use when a makit adapter decision depends on what codex `app-server` or an ACP agent (pi-acp, claude-code-acp) *actually* does — concurrency, steering, cancellation, error shapes, capability quirks — and the spec/docs are silent or the fake transport in the unit tests would just encode your assumption.

## Procedure
1. Mine the binary before writing any client: `strings $(readlink -f $(which codex)) | grep -o 'turn/[a-zA-Z]*' | sort -u` and grep for param/error names (e.g. expectedTurnId, activeTurnNotSteerable). For a node-based agent (pi-acp) the dist bundle is readable JS — grep it for `spawn(`, `env:`, argv arrays; that often answers the question statically before any process runs.
2. **Env-delivery questions: use a shim, not a client.** To prove whether a var reaches a grandchild, point the parent's binary-override env var at a wrapper script that dumps its own env, e.g. `PI_ACP_PI_COMMAND=/tmp/spike/pi-shim.sh` where the shim is `env > /tmp/spike/dump.txt; exec sleep 60`. The shim sits at the exact spawn site, so it observes precisely the env the real binary would receive — deterministic, and it costs no model tokens.
3. Write a throwaway stdio client in /tmp as a plain `.mjs` (node built-ins only): line-framed JSON-RPC over child stdin/stdout, a `send()` that returns a promise keyed by id, a `notify()`, and a catch-all handler that auto-approves ANY server→client request (`{decision:'accept', approved:true, currentTime:…}` for codex; `{outcome:{outcome:'selected',optionId}}` for ACP `session/request_permission`) — otherwise the turn stalls and you misread it as a protocol answer.
4. Log every frame to a file, but filter streaming deltas/chunks out of the main log (write them to a separate timestamped file); the interesting signal is turn/item lifecycle, not tokens.
5. Drive a turn long enough to leave a window: a 'count 1..60 with a fun fact each, no tools' prompt streams ~30s. Sleep ~6s after `turn/started`, then fire the experiment. Use a second message with an unmistakable marker ('reply with the single word BANANA') so you can tell absorption from a new turn.
6. Wait a FIXED settle window (SETTLE=45000) after the experiment — never `while (activeTurns.size > 0)`, or you will exit before a late-announced turn and cannot distinguish 'phantom' from 'not yet'.
7. Run one process per hypothesis (mode argv), including the negative cases: stale precondition, no active turn, wrong id. Error strings are the most reusable output.
8. Prefer a production observation over a spike when one is available: if the agent you are running as is itself under the transport in question, inspect your own `env` and `ps -o ppid=` chain — that is stronger evidence than any harness.
9. Reduce the finding to a keyless unit test against the existing fake transport (server/src/adapters/*.test.ts) and make the fake TRUTHFUL first (e.g. `turn/start` returning a fresh `t${++seq}` each call) — the assumption usually lives in the fake.
10. Re-verify end to end through the real adapter afterwards: a small script importing e.g. CodexAppServerAdapter with the real subprocess, asserting the observable makit state (status ends `idle`). Run it with `pnpm exec tsx` from `server/`.
11. Write the outcome back into the spec that owed the spike — including when the spec's *premise* was wrong, not just its conclusion — and clean /tmp scratch so `git status --porcelain` is clean.
## Pitfalls
- tsx run from outside `server/` on a `.ts` file fails with 'Top-level await is currently not supported with the cjs output format' — name the scratch file `.mts` (or wrap in an async main).
- Not replying to server→client requests (approvals, fs/read_text_file, currentTime/read) makes the agent look hung; every stall should be attributed before drawing conclusions.
- codex prints noise on stderr (`codex_memories_write::phase2 Phase 2 no changes`) and starts MCP servers from the user's real config — capture stderr but don't treat it as failure; use a scratch cwd like /tmp/spike-steer/work.
- A request reply is not proof of state: codex's mid-turn `turn/start` returns `status:inProgress` for a turn id that never exists. Only notifications (`turn/started` / `turn/completed`, ACP `state_update`) are authoritative.
- Live spikes cost real tokens/quota on the user's account — keep prompts short-output and the number of runs small. For an *env delivery* question you need NO model call at all: shim the agent binary (see Procedure) and stop after `session/new`.
- **`ps -E` cannot read another process's environment on macOS (SIP)** and silently returns only the argv, so it will 'prove' an env var is absent. This nearly inverted a SPEC-46 decision. Never answer an env question with `ps`; always run a control (spawn `sleep` with a known marker var and try to read it back) before trusting any env-inspection tool.
- Don't infer that two `SpawnOpts` fields share a delivery seam. In pi-acp, `extensions` are dropped because argv is hardcoded (`--mode rpc --no-themes`) while `env` passes fine by inheritance (`env: process.env`) — a spec that reasons 'same seam' about both is wrong.
- Don't leave the spike test in `server/src/`; a failing red test committed by accident poisons CI. Keep scratch in /tmp and land only the reduced regression test.
## Verification
1. Every claim you report maps to a line you can point at in the spike log (frame direction, method, ids).
2. The reduced unit test fails before the fix and passes after (`pnpm exec tsx --test src/adapters/<file>.test.ts`).
3. `pnpm test` + `pnpm typecheck` green in `server/`.
4. The real-binary harness prints the expected end state (e.g. `statuses: … -> idle`).
5. For a feature (not just a fix), re-run the live harness through a real `Session` — not just the adapter — so the decision path the server actually uses is what gets proven. Pattern: `new XAdapter({})` → `await adapter.start({cwd, sessionId})` → `new Session({projectId, agent, adapter})` → `session.sendUserMessage(...)`, then assert on collected events + `session.status`.
6. `git status --porcelain` is clean of scratch files before committing.
