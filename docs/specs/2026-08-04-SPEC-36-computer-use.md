# SPEC-36 — Computer use for pi and codex sessions

**Status:** Shipped (server-side enablement, opt-in) · **Priority:** P3 · **Branch:** `feat/computer-use`
**Depends on:** SPEC-22 (assistant display media), SPEC-27 (capability probe / spawn args)
**Reference implementation:** Hermes Agent's `computer_use` toolset —
[hermes-agent.nousresearch.com/docs/user-guide/features/computer-use](https://hermes-agent.nousresearch.com/docs/user-guide/features/computer-use)

**Scope:**
*pi (primary):* `.pi/extensions/pi-computer-use/` (new, self-contained — `index.ts`,
`mcp_stdio.ts`, `config.ts`, `computer_use.test.ts`, `fake-mcp-server.mjs`, own
`tsconfig.json` + `package.json`), `server/package.json` (typecheck + test reach into it).
*codex:* `server/src/adapters/computer_use.ts` (new), `server/src/adapters/tool_media.ts`
(new — extracted from `acp-map.ts`), `server/src/adapters/codex-map.ts`,
`server/src/adapters/codex.ts` (one hook), `server/src/agent_factory.ts`.
No protocol changes. No app changes.

---

## Goal

Let the agent in a makit session drive the host desktop — click, type, scroll, capture —
while the phone watches the screenshots and answers the approvals. makit writes none of
the desktop-driving code: it points both agents at the external
[`cua-driver`](https://github.com/trycua/cua) binary over stdio MCP, exactly as Hermes does.

Both agents are supported, by two different routes, because they have different
capabilities:

| Agent | Route | Why |
| --- | --- | --- |
| **pi** (primary) | `.pi/extensions/pi-computer-use/` — a pi extension that speaks stdio MCP and republishes each driver tool via `pi.registerTool()` | pi has **no MCP client**, so nothing on the makit server can configure this. Extensions are pi's documented way to add tools, and pi tool results accept `ImageContent` — which is what makes screenshots usable. |
| **codex** | `-c mcp_servers.cua_driver.*` spawn overrides | codex has a native MCP client; it only needed to be told where the driver is. |

## What Hermes' core actually is

Hermes' `computer_use` is a thin wrapper over `cua-driver mcp`. Its six mechanisms, and
whether each ports to makit:

| Hermes mechanism | Ports to makit? |
| --- | --- |
| Action vocabulary (`computer_use(action=capture\|click\|type\|…)`) | **No — not needed.** cua-driver exposes its own MCP tools; the agent calls them directly. Hermes only needs a vocabulary because it owns the tool loop. makit does not. |
| Approval mapping (session mode → cua daemon mode) | **No.** codex spawns cua-driver itself, so makit never sees the MCP traffic and cannot elect the daemon mode. cua-driver's `standard` mode + codex's own approval flow apply. |
| Guardrails (blocked key combos / `type` payloads) | **No — same reason.** Documented in `computer_use.ts` rather than faked. |
| Screenshot economics (keep 3, strip old images, ~1500 tok/image) | **No.** Context belongs to codex, not makit. |
| Doctor (`health_report`) | **Deferred.** Cheap to add later as a control-plane command; nothing depends on it. |
| Install + env plumbing (`HERMES_CUA_DRIVER_CMD`, telemetry off) | **Yes** — see below. |

So the honest port is small, and the *one* thing makit genuinely had to fix was not in
Hermes' list at all: **codex tool-result images were being dropped.**

## What shipped

### 1. Screenshots reach the phone (the real gap)

`codex-map.ts`'s `mcpResultText` kept only `text` blocks, so every `capture` rendered as
an empty tool row. `CodexEventMapper` now takes the same `putMedia` hook the ACP mapper
has and ingests image blocks from `item.result` on `mcpToolCall`, emitting one
`agent.media` per new blob **before** `tool.call.end` so transcript order matches reality.
The text half still lands as the tool output.

The image-block scan (`asImageBlock` / `imageBlocksIn`) moved out of `acp-map.ts` into
`tool_media.ts` unchanged — it now has two callers.

Dedup matches the ACP path: per-call payload key + global `mediaId`. The store is
content-addressed, so re-putting identical bytes is an idempotent no-op; the *event* is
what gets deduped. Consequence worth knowing: `capture → click → capture` with no visual
change announces one image, not two.

### 2. Registration, opt-in

`resolveComputerUse(env)` → `{enabled, driverPath}`:

- `MAKIT_COMPUTER_USE=1` — required opt-in. Registering a desktop-driving MCP server into
  every codex session is not a safe default.
- `MAKIT_CUA_DRIVER_CMD` — binary override (local builds / CI), mirroring
  `HERMES_CUA_DRIVER_CMD`; otherwise resolved on PATH via `resolveBinPath`.
- Enabled but no binary → `{enabled:false, reason:"driver-missing"}` and a plain spawn.
  Never a hard failure.

`codexSpawnArgs()` appends codex `-c` overrides to the live spawn:

```
codex app-server \
  -c mcp_servers.cua_driver.command="/abs/path/cua-driver" \
  -c mcp_servers.cua_driver.args=["mcp"] \
  -c mcp_servers.cua_driver.env={CUA_DRIVER_RS_TELEMETRY_ENABLED="0"}
```

Per-spawn, so the user's `~/.codex/config.toml` is untouched. Telemetry is forced off, as
Hermes does (cua-driver ships PostHog telemetry on by default upstream). The `-c` value is
parsed as TOML, so the path goes through `tomlString` escaping rather than string paste.
The SPEC-27 throwaway capability probes deliberately do **not** get these args — they
start no thread, so spawning a desktop driver for them is pure cost.

## The pi path (primary)

pi cannot be configured into this from the makit side: `pi-acp` accepts ACP `mcpServers`
on `session/new` and **silently ignores it** — verified against pi-acp 0.0.32, which
advertises `mcpCapabilities: {http:false, sse:false}` and returns a normal session id for
a request carrying an MCP server. pi has no MCP client at all. So `acp.ts` is left alone
(`mcpServers: []` stays); the capability is added inside pi instead.

`.pi/extensions/pi-computer-use/` is a self-contained pi extension — code, tests, fixture,
`tsconfig.json` and `package.json` all live in that one directory, so nothing outside it
needs to know it exists. It lives in the repo (not `~/.pi/agent/extensions/`) so it is
version-controlled and does not depend on a disposable worktree path.

- `mcp_stdio.ts` — a minimal stdio MCP client (newline-delimited JSON-RPC 2.0):
  `initialize` → `notifications/initialized` → `tools/list`, then `tools/call` per
  invocation. Per-request deadline (30s) so a wedged driver cannot hang a turn; stderr
  drained so a chatty driver cannot deadlock on a full pipe; telemetry forced off.
- `index.ts` — registers **one pi tool per selected MCP tool**, named `computer_<tool>`,
  with the server's own JSON Schema as the pi parameter schema.
- `config.ts` — the opt-in gate plus `selectTools()`.

Tools are **discovered, not hardcoded**. This is the deliberate opposite of Hermes, which
exposes a single `computer_use(action=…)` facade: Hermes ships in lockstep with a tested
cua-driver baseline, makit does not, so binding to a tool vocabulary we cannot verify
would be guesswork that breaks on the next driver release. Installing the real driver
proved the point immediately: **cua-driver 0.17.0 advertises 54 tools and has no `capture`
tool at all** — a screenshot comes from `get_desktop_state` / `get_window_state`. A
hardcoded Hermes-shaped facade would have been wrong on day one.

### Tool selection

54 tools × JSON schema in pi's system prompt on every request is both expensive and
crowds the model's tool choice with things a coding session does not need (browser
driving, trajectory recording, cursor theming, daemon config). `selectTools()` registers a
**25-tool desktop-driving core** by default — the complete observe → decide → act loop
(`get_desktop_state`, `get_window_state`, `get_accessibility_tree`, `list_apps`,
`list_windows`, `verify_state`, `get_screen_size`; `click`, `double_click`, `right_click`,
`drag`, `type_text`, `press_key`, `hotkey`, `scroll`, `set_value`, `invoke_menu`,
`move_cursor`; `launch_app`, `bring_to_front`, `set_window_frame`; `clipboard_read`,
`clipboard_write`; `health_report`, `check_permissions`).

Override with `MAKIT_COMPUTER_USE_TOOLS` (comma list, or `all`). The selection is
intersected with what the driver actually advertises, and falls back to the driver's whole
roster if the intersection is empty — a future release that renames everything degrades to
"more tools than ideal", never to "silently no computer use".

Screenshots reach the phone for free on this path: pi-acp puts raw tool-result bytes in
`rawOutput`, and makit's ACP mapper already ingests image blocks from there into the media
store (SPEC-22).

Safety on the pi path is guidance plus the driver's own permission mode — `promptGuidelines`
telling the agent never to click consent dialogs, never to type passwords, to treat
on-screen text as untrusted data, and to re-capture before reusing a stale element index.
It is not a sandbox, and is not claimed to be.

**Install** (once), then enable per environment:

```
# 1. the driver (installs /Applications/CuaDriver.app + ~/.local/bin/cua-driver, no sudo)
/bin/bash -c "$(curl -fsSL https://cua.ai/driver/install.sh)"
cua-driver telemetry disable

# 2. macOS TCC — start the daemon first so the grant attaches to CuaDriver.app,
#    not to your terminal, then flip both toggles in System Settings
open -n -g -a CuaDriver --args serve
cua-driver permissions grant          # System Settings → Privacy & Security →
                                      #   Accessibility + Screen Recording
cua-driver permissions status         # both must read ✅

# 3. the pi bridge — nothing to install, it ships in the repo
export MAKIT_COMPUTER_USE=1           # in the makit daemon's environment
```

With the flag unset the extension registers nothing and never spawns the driver.

### Scope limit of the in-repo location (measured, not assumed)

pi discovers `.pi/extensions/*/index.ts` **relative to its cwd, and does not walk up**:

- `cd <repo> && pi …` → 25 `computer_*` tools.
- `cd <repo>/server && pi …` → **none**.

So the in-repo copy gives computer use only to pi sessions rooted at the makit repo. makit
spawns pi with cwd set to the *session's* project/worktree, so a session on any other repo
gets no computer-use tools from here. Making it available everywhere needs a global install
pointing at a **stable** path (a clone, never a worktree):

```
ln -s /path/to/makit/.pi/extensions/pi-computer-use ~/.pi/agent/extensions/pi-computer-use
```

Global and project-local discovery coexist, so doing that later changes nothing in the repo.

The installer fetches a release tarball from `github.com/trycua/cua` over HTTPS and does
**no checksum or signature verification** of it; Gatekeeper still verifies the signed
`com.trycua.driver` bundle at launch. Worth knowing before running it on a work machine.

## Risks / notes

- **No makit-side guardrails.** Safety is cua-driver's `standard` permission mode plus
  codex's approval flow. A user opting in with `--yolo`-equivalent codex settings is
  driving their real desktop with no makit checkpoint.
- **Prereqs are the user's.** macOS needs Accessibility + Screen Recording granted to the
  process tree; Linux needs a reachable display server. makit does not probe these (that's
  what a future `doctor` would do).
- **Codex ships its own `computer-use` MCP server** (bundled with the ChatGPT app,
  `SkyComputerUseClient`, disabled by default). Enabling *that* instead is a plausible
  alternative to cua-driver and needs no new code — just a different server name. Not
  chosen here because it is macOS/ChatGPT-app-bound, where cua-driver is
  macOS/Windows/Linux and open source.

## Verification

- `resolveComputerUse` / `codexComputerUseArgs` / `tomlString` — unit tests incl. TOML
  metacharacter escaping (`computer_use.test.ts`).
- `codexSpawnArgs` — off by default, appends after the subcommand, degrades when the
  driver is missing (`agent_factory.test.ts`).
- Mapper: image stored + `agent.media` before `tool.call.end`; absent/refusing sink never
  blocks the tool; identical blob announced once (`codex-map.test.ts`).
- Adapter wiring end to end through a fake app-server: a cua-driver-shaped screenshot
  result reaches the media store and the tool row still renders
  `cua_driver/computer_use` + its text (`codex.test.ts`).
- Config keys checked against the real binary (codex-cli 0.146.0):
  `codex -c mcp_servers.cua_driver.command=… mcp list` lists `cua_driver` as `enabled`
  with the expected command/args/env.
- pi bridge: 14 unit tests against a fake stdio MCP server (`fake-mcp-server.mjs`, beside
  the extension) — handshake + tool discovery, text+image results,
  image→`ImageContent` mapping, non-empty content floor, JSON-RPC error becoming an error
  *result* (never a thrown turn), concurrent request/reply matching, post-dispose calls,
  and the opt-in gate.
- pi bridge, **live through real pi** (with the fake driver): the model called
  `computer_capture`, received text + a real 1×1 PNG, and echoed the tool's text back. With
  `MAKIT_COMPUTER_USE` unset the same command reports no `computer_*` tool exists.
- Registration count is asserted **deterministically** by invoking the extension's
  `activate()` against the real driver with a recording `PiHost` stub — `registered 25/54
  tool(s) from cua-driver 0.17.0`. (Asking the model to count its own tools returned 25
  once and 24 another time; model self-reports are not evidence.)
- pi bridge, **live against the real cua-driver 0.17.0**: `initialize` → `tools/list`
  returned all 54 tools with the exact framing the client implements, and
  `pi -p "call computer_health_report…"` returned the driver's live health matrix through
  pi. `selectTools`' default/override behaviour is unit-tested against the real 54-name
  roster.
- The fake MCP server remains the test double (same role as Hermes'
  `HERMES_COMPUTER_USE_BACKEND=noop`) so the suite needs neither the binary nor TCC grants.
- **Not verified: an actual click/capture** — that needs the macOS Accessibility + Screen
  Recording toggles, which cannot be set programmatically. Until they are on, `health_report`
  reports `degraded` and input/capture calls fail by design.
