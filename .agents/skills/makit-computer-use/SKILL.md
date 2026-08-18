---
name: makit-computer-use
description: Wire, verify, or debug computer use (cua-driver desktop control) in makit's pi and codex sessions. Use when desktop-driving tools are missing from a session, when changing `.pi/extensions/pi-computer-use/`, when upgrading cua-driver, or when an agent needs to click/type/capture the host GUI from a makit session.
---
# Computer use in makit (cua-driver)

makit writes no desktop-driving code. It points both agents at the external
[`cua-driver`](https://github.com/trycua/cua) binary over stdio MCP. Design rationale lives
in [`docs/specs/20260804-003600-SPEC-computer-use.md`](../../../docs/specs/20260804-003600-SPEC-computer-use.md).

## Contents
- [Two routes, one per agent](#two-routes-one-per-agent)
- [Enable it](#enable-it)
- [Verify it](#verify-it)
- [Traps](#traps)
- [Deeper platform docs](#deeper-platform-docs)

## Two routes, one per agent

| Agent | Route | Why |
| --- | --- | --- |
| **pi** | `.pi/extensions/pi-computer-use/` — a pi extension speaking stdio MCP, republishing each driver tool via `pi.registerTool()` as `computer_<mcp_tool>` | pi has **no MCP client**, so nothing on the makit server can configure this. Extensions are pi's documented way to add tools, and pi tool results accept `ImageContent`, which is what makes screenshots usable. |
| **codex** | `codexSpawnArgs()` in `server/src/agent_factory.ts` appends `-c mcp_servers.cua_driver.*` to `codex app-server` | codex has a native MCP client; it only needed to be told where the driver is. |

Screenshots reach the phone on both paths: `CodexEventMapper` and `AcpEventMapper` ingest
image blocks from MCP tool results into the media store via the shared
`server/src/adapters/tool_media.ts` (SPEC-assistant-display-media).

## Enable it

```sh
# 0. is it already there?
cua-driver --version && cua-driver doctor    # want `ok`, not `degraded`

# 1. driver (review the script first: it fetches a GitHub tarball with NO checksum check)
/bin/bash -c "$(curl -fsSL https://cua.ai/driver/install.sh)"
cua-driver telemetry disable

# 2. macOS grants — MANUAL, cannot be automated (SIP-protected TCC).
#    Start the daemon FIRST so the grant attaches to CuaDriver.app, not your terminal.
open -n -g -a CuaDriver --args serve
cua-driver permissions grant     # then flip Accessibility + Screen Recording in
                                 # System Settings → Privacy & Security
cua-driver permissions status    # both must read ✅

# 3. makit — the pi extension ships in the repo, nothing to install
export MAKIT_COMPUTER_USE=1      # in the makit daemon's environment
```

Optional: `MAKIT_CUA_DRIVER_CMD` pins a binary; `MAKIT_COMPUTER_USE_TOOLS` overrides the
allowlist (comma list, or `all`). With `MAKIT_COMPUTER_USE` unset the extension registers
nothing and never spawns the driver.

## Verify it

Verify registration **deterministically**. Asking the model to count its own tools returned
25 once and 24 another time — model self-reports are not evidence.

```sh
cd server && MAKIT_COMPUTER_USE=1 node --import tsx -e '
import a from "../.pi/extensions/pi-computer-use/index.ts";
const n = []; await a({ registerTool: d => n.push(d.name), on: () => {}, log: m => console.log(m) });
console.log(n.length, n.join(", "));'
# → [computer-use] registered 25/54 tool(s) from cua-driver (cua-driver 0.17.0)
```

```sh
# tests: 14, need neither the driver nor TCC grants (fake MCP server stands in)
cd server && node --import tsx --test "../.pi/extensions/**/*.test.ts"
cd server && pnpm typecheck        # two tsc invocations: server + extension

# codex side
codex -c mcp_servers.cua_driver.command="$(which cua-driver)" \
      -c mcp_servers.cua_driver.args='["mcp"]' mcp list   # expect status `enabled`

# live pi smoke (must run from the repo root — see traps)
cd <repo> && MAKIT_COMPUTER_USE=1 pi -p "Call computer_health_report and report its first line."
```

Then check the driver's own health before you blame makit:

```sh
cua-driver doctor                # `ok`, not `degraded`
cua-driver permissions status    # Accessibility + Screen Recording both ✅
```

Without grants, `get_desktop_state` returns `isError` with
`screencapture failed … could not create image from display`. That exact message means the
wiring is fine and only TCC is missing.

## Traps

- **There is no `capture` tool.** Screenshots come from `get_desktop_state` /
  `get_window_state`. cua-driver 0.17.0 advertises **54** tools and the roster changes
  between releases — which is why tools are discovered via `tools/list` and never hardcoded.
  A Hermes-style `computer_use(action=capture)` facade would have been wrong on day one.
- **Registering all 54 tools** bloats pi's prompt and crowds tool choice. `selectTools()` in
  `config.ts` trims to a 25-tool core, intersected with what the driver advertises, and falls
  back to the **full** roster when the intersection is empty — so a renamed roster degrades
  to "too many tools", never to "silently no computer use".
- **pi does not walk up for `.pi/extensions/`.** `cd <repo> && pi` → 25 tools;
  `cd <repo>/server && pi` → **zero**. makit spawns pi with cwd set to the *session's* own
  project, so the in-repo copy only serves sessions rooted at the makit repo. For global
  reach, symlink it from `~/.pi/agent/extensions/` at a stable **clone** — never at a git
  worktree, which gets disposed and leaves a dangling link.
- **pi-acp accepts ACP `mcpServers` and silently ignores it** (advertises
  `mcpCapabilities:{http:false,sse:false}`). Plumbing `mcpServers` through
  `server/src/adapters/acp.ts` looks like it works and does nothing. The extension is the
  only route.
- **A fake MCP fixture must return a real decodable PNG.** A bogus base64 image block makes
  the provider reject the whole turn with `Validation error: … Could not process image`,
  which looks like a bridge bug and is not.
- **Never fake `PATH` in a passed-in env** to test "driver missing": `resolveBinPath` reads
  the real `process.env.PATH`, so such a test passes only while cua-driver happens to be
  uninstalled. Inject the resolver: `codexSpawnArgs(env, resolve)`.
- **Extension build constraints.** It cannot live under `server/` (`rootDir` violation);
  there is no `node_modules` beside `.pi/`, so its `tsconfig.json` points `typeRoots` at
  `../../../server/node_modules/@types`; and its `package.json` must set `"type": "module"`
  or `import.meta` fails to compile.
- **makit adds no tool-level guardrails.** The driver is a separate process reached over MCP,
  so makit never sees the traffic. Hermes' blocked key combos, blocked `type` payloads and
  screenshot context economics are **not** portable. Safety is cua-driver's `standard`
  permission mode plus the extension's `promptGuidelines`. Do not describe it as a sandbox.
- **`cd server && pnpm test` takes ~5.5 minutes.** Run only affected test files while
  iterating; one full run before handing off.

## Deeper platform docs

Element tokens, the macOS no-foreground contract, browser-page interaction, trajectory
recording and embedding are documented by the upstream pack, maintained by the cua team:

```sh
cua-driver skills install    # → ~/.cua-driver/skills/cua-driver/
cua-driver skills status
```

It links into `~/.agents/skills/cua-driver` (labelled "Codex" by cua, but **pi reads that
directory too**), `~/.claude/skills/` and `~/.config/opencode/skills/`. It documents **raw**
MCP tool names; in a makit pi session those same tools are prefixed `computer_`.
