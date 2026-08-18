---
name: "acp-session-fixture-recorder"
description: "Record a real ACP agent session (pi-acp, codex) into a JSON fixture for deterministic replay testing, capturing tool calls, thinking, and UI interactions without live agent dependency."
---
## When to Use
Use when debugging adapter bugs (stuck tools, missing events, UI rendering regressions) and you need a deterministic, replayable session fixture that includes thinking tokens, multiple tool types (edit, write, read, grep, bash, ask_user), and sub-agent calls. Replaying the fixture through the mapper avoids re-running the live agent and captures exactly what the app saw.

## Procedure
1. Add socket interception to `makit-server` startup (before adapter.start) to tap the raw ACP JSON-RPC stream
2. Prompt the user to interact with pi-acp: run multiple tool calls (edit a file, read, grep, bash, ask a question), trigger thinking, let sub-agents run
3. Capture all `session/update` frames (not tool.call.*, just raw ACP frames) into a `.jsonl` file indexed by seq
4. Create a `SessionFixture` TypeScript class that implements the ACP transport interface but replays captured frames
5. Write unit tests that feed the fixture through `AcpEventMapper` and assert the resulting chat_items match expected one-liners, diff bodies, and lifecycle
6. Dart-side test: mount `SrvRequestHandler` + `chat_transcript`, feed app events from fixture replay, take screenshots or assert widget tree

## Pitfalls
- Do not intercept at the HTTP/WebSocket framing layer — you need parsed JSON-RPC frames, not raw bytes
- Replay fixture must preserve seq/frame ordering and emit at the pace the mapper expects (not all-at-once)
- If fixture includes ask_user, mock the UICall response path (HTTP loopback) or SrvRequestHandler's permissionResolved future
- Thinking tokens and tool deltas must be captured frame-by-frame; coalescing loses the ordering the UI depends on
- CODEX app-server variant (not ACP session/update): it is request/response + notifications. Record {t:'send'|'recv', id, method, params, result} frames. Build the replay CodexTransport by keying recorded responses to the REQUEST method (map send.id->method), and split notifications at the first 'turn/started': emit the pre-turn batch after thread/start, the turn batch after turn/start. Reference impl: server/src/adapters/codex-fixture.test.ts.
- Codex serviceTier/'Fast' semantics can ONLY be learned by a live turn/start probe: the app-server accepts ANY serviceTier string (no validation) and echoes the EFFECTIVE tier in thread/settings/updated.threadSettings.serviceTier. 'priority'/'fast' -> priority (Fast, 1.5x); null/omitted/'default' -> default (standard). Send a trivial prompt + turn/interrupt immediately to keep it cheap.
- Sanitize recorded fixtures before committing: normalize temp cwd + /Users/<name> paths to placeholders; drop account/rateLimits, tokenUsage, mcp/hook/warning noise; keep thread/settings + `item/*` + `turn/*` lifecycle.
- A fixture records real `read`, `grep`, `bash` and `ask_user` payloads, so it can carry secrets, tokens, private source, or personal data. Scan the file before you commit it: grep for the env var names the session had, for `Bearer `, `sk-`, `ghp_`, `-----BEGIN`, `Authorization`, and for every path under `/Users/`. Redact each hit, then re-read the diff by eye. Do not commit a fixture with one unredacted hit left — record the prompt instead and re-record with a scrubbed project.
- Capability cache gotcha (SPEC-new-session-config-at-spawn): new-session DRAFT options come from ~/.makit/capability-cache.json keyed by fingerprintAgent (binary+config only, NOT makit code). After changing an adapter's config-option projection, bump the `catalog-schema:N` token in fingerprintAgent (server/src/adapters/catalog.ts) or drafts keep serving stale cached options.
## Verification
1. Recorded fixture file exists and contains ≥5 unique tool types (bash, edit, read, write, grep, ask_user) with complete lifecycle (start, delta, end)
2. Replay through AcpEventMapper produces correct AdapterEvents with matching callIds and content
3. Dart UI test using fixture replay renders all tool one-liners correctly (Ran, Edited, Read, Wrote, Grep) without hanging on any tool.call.start
4. Fixture can be committed to repo and re-run deterministically in CI
