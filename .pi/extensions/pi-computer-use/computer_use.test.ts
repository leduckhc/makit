import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { McpStdioClient, toPiContent } from "./mcp_stdio.js";
import { resolveComputerUse, piToolName, selectTools } from "./config.js";

const FAKE = join(dirname(fileURLToPath(import.meta.url)), "fake-mcp-server.mjs");

function client(env: Record<string, string> = {}) {
  return new McpStdioClient({ command: process.execPath, args: [FAKE], env });
}

test("handshakes and discovers the server's tools", async () => {
  const c = client();
  const tools = await c.start();
  assert.deepEqual(tools.map((t) => t.name), ["capture", "click"]);
  assert.equal(tools[0].description, "Screenshot a window with numbered elements.");
  // The JSON Schema comes straight from the server — we never hardcode a tool shape.
  assert.deepEqual((tools[1].inputSchema as any).required, ["element"]);
  assert.equal(c.serverInfo?.name, "fake-cua-driver");
  await c.dispose();
});

test("a tool call returns text and image content", async () => {
  const c = client();
  await c.start();
  const res = await c.call("capture", { app: "Mail", mode: "som" });
  assert.equal(res.isError, false);
  assert.deepEqual(res.content, [
    { type: "text", text: "captured Mail (2 elements)" },
    { type: "image", data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC", mimeType: "image/png" },
  ]);
  await c.dispose();
});

test("image blocks map onto pi's ImageContent, text passes through", () => {
  assert.deepEqual(
    toPiContent([
      { type: "text", text: "captured" },
      { type: "image", data: "AAAA", mimeType: "image/png" },
      { type: "audio", data: "zzz", mimeType: "audio/wav" },
    ]),
    [
      { type: "text", text: "captured" },
      { type: "image", data: "AAAA", mimeType: "image/png" },
    ],
  );
});

test("an empty result still yields a non-empty content array", () => {
  assert.deepEqual(toPiContent([]), [{ type: "text", text: "(no output)" }]);
  assert.deepEqual(toPiContent(undefined), [{ type: "text", text: "(no output)" }]);
});

test("a JSON-RPC error becomes an error result, not a thrown call", async () => {
  const c = client({ FAKE_MCP_FAIL: "1" });
  await c.start();
  const res = await c.call("capture", {});
  assert.equal(res.isError, true);
  assert.match((res.content[0] as any).text, /screen recording denied/);
  await c.dispose();
});

test("concurrent calls are matched to their own replies", async () => {
  const c = client();
  await c.start();
  const [a, b] = await Promise.all([c.call("click", { element: 1 }), c.call("click", { element: 2 })]);
  assert.match((a.content[0] as any).text, /clicked 1/);
  assert.match((b.content[0] as any).text, /clicked 2/);
  await c.dispose();
});

test("calls after dispose fail as an error result, not a hang or a throw", async () => {
  const c = client();
  await c.start();
  await c.dispose();
  const res = await c.call("click", { element: 1 });
  assert.equal(res.isError, true);
  assert.match((res.content[0] as any).text, /not running/);
});

// ---------- opt-in gate (shared contract with SPEC-computer-use's codex path) ---------

test("the extension is inert unless MAKIT_COMPUTER_USE=1", () => {
  assert.equal(resolveComputerUse({}).enabled, false);
  assert.equal(resolveComputerUse({ MAKIT_COMPUTER_USE: "0" }).enabled, false);
  const on = resolveComputerUse({ MAKIT_COMPUTER_USE: "1", MAKIT_CUA_DRIVER_CMD: "/opt/cua-driver" });
  assert.deepEqual(on, { enabled: true, command: "/opt/cua-driver", args: ["mcp"] });
});

test("the driver command defaults to cua-driver on PATH", () => {
  assert.deepEqual(resolveComputerUse({ MAKIT_COMPUTER_USE: "1" }), {
    enabled: true,
    command: "cua-driver",
    args: ["mcp"],
  });
});

test("pi tool names are namespaced and sanitized", () => {
  assert.equal(piToolName("capture"), "computer_capture");
  assert.equal(piToolName("health_report"), "computer_health_report");
  assert.equal(piToolName("set-agent-cursor.style"), "computer_set_agent_cursor_style");
});

// ---------- tool selection (the real driver advertises 54 tools) ------------

/** The real cua-driver 0.17.0 roster, verified via `tools/list`. */
const REAL_54 = [
  "list_apps", "list_windows", "get_window_state", "verify_state", "launch_app", "kill_app",
  "bring_to_front", "set_window_frame", "invoke_menu", "click", "double_click", "right_click",
  "drag", "type_text", "press_key", "hotkey", "set_value", "scroll", "clipboard_read",
  "clipboard_write", "get_screen_size", "get_desktop_state", "get_cursor_position", "move_cursor",
  "set_agent_cursor_enabled", "set_agent_cursor_motion", "set_agent_cursor_theme",
  "get_agent_cursor_state", "check_permissions", "health_report", "get_config", "set_config",
  "get_accessibility_tree", "zoom", "page", "get_browser_state", "browser_prepare",
  "browser_navigate", "browser_click", "browser_type", "browser_dialog",
  "browser_set_input_files", "browser_download", "browser_pointer", "start_recording",
  "stop_recording", "get_recording_state", "replay_trajectory", "install_ffmpeg", "start_session",
  "escalate_session", "get_session_state", "end_session", "check_for_update",
];

test("the default selection is the desktop-driving core, not all 54 tools", () => {
  const picked = selectTools(REAL_54, {});
  assert.ok(picked.length < 30, `expected a trimmed set, got ${picked.length}`);
  // The observe/act loop must be complete: state in, input out.
  for (const need of ["get_desktop_state", "get_window_state", "get_accessibility_tree", "click", "type_text", "press_key", "scroll", "list_apps", "health_report"])
    assert.ok(picked.includes(need), `missing ${need}`);
  // Noise stays out.
  for (const skip of ["browser_navigate", "start_recording", "set_agent_cursor_theme", "set_config", "install_ffmpeg", "check_for_update"])
    assert.ok(!picked.includes(skip), `${skip} should not be registered by default`);
});

test("the allowlist can be overridden, and 'all' opts into everything", () => {
  assert.deepEqual(selectTools(REAL_54, { MAKIT_COMPUTER_USE_TOOLS: "click, browser_navigate" }), ["browser_navigate", "click"].sort());
  assert.equal(selectTools(REAL_54, { MAKIT_COMPUTER_USE_TOOLS: "all" }).length, 54);
});

test("a requested tool the driver does not advertise is dropped, not invented", () => {
  assert.deepEqual(selectTools(REAL_54, { MAKIT_COMPUTER_USE_TOOLS: "click,capture" }), ["click"]);
});

test("a driver advertising none of the default set still yields its tools", () => {
  // Forward compatibility: a renamed roster must not silently register nothing.
  assert.deepEqual(selectTools(["future_tool_a", "future_tool_b"], {}), ["future_tool_a", "future_tool_b"]);
});

test("after the driver exits, the next call fails at once instead of waiting for the deadline", async () => {
  const c = new McpStdioClient({ command: process.execPath, args: [FAKE], timeoutMs: 5_000 });
  await c.start();

  // The driver dies mid-request: that call fails with the exit reason.
  const crashed = await c.call("crash", {});
  assert.equal(crashed.isError, true);

  // A *subsequent* call must not be written to the dead child's stdin (an
  // unhandled EPIPE can take down the whole pi process) and must not sit until
  // the request deadline expires.
  const startedAt = Date.now();
  const res = await c.call("click", { element: 1 });
  assert.equal(res.isError, true);
  assert.match((res.content[0] as any).text, /not running/);
  assert.ok(Date.now() - startedAt < 1_000, `waited ${Date.now() - startedAt}ms; expected an immediate failure`);
  await c.dispose();
});
