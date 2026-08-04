/**
 * Opt-in gate for pi-side computer use. Deliberately duplicates the small
 * env-var contract of `server/src/adapters/computer_use.ts` (SPEC-36) instead of
 * importing it: this file is loaded by **pi's** module loader inside pi's own
 * process, not by the makit server, so it must stay dependency-free.
 *
 * - `MAKIT_COMPUTER_USE=1` — required opt-in. Without it the extension registers
 *   nothing and never spawns a desktop driver.
 * - `MAKIT_CUA_DRIVER_CMD` — driver binary override (local builds / a fake
 *   driver in tests); otherwise `cua-driver` is resolved on PATH by the OS.
 * - `MAKIT_COMPUTER_USE_TOOLS` — comma-separated allowlist, or `all`. Defaults to
 *   {@link DEFAULT_TOOLS}.
 */

export type ComputerUseConfig =
  | { enabled: true; command: string; args: string[] }
  | { enabled: false };

export function resolveComputerUse(env: Record<string, string | undefined>): ComputerUseConfig {
  if (env.MAKIT_COMPUTER_USE !== "1") return { enabled: false };
  return { enabled: true, command: env.MAKIT_CUA_DRIVER_CMD || "cua-driver", args: ["mcp"] };
}

/**
 * The pi tool name for an MCP tool. Namespaced so a driver tool called `click`
 * cannot shadow (or be confused with) a built-in, and sanitized because pi tool
 * names reach provider APIs that only accept `[A-Za-z0-9_]`.
 */
export function piToolName(mcpTool: string): string {
  return `computer_${mcpTool.replace(/[^A-Za-z0-9_]/g, "_")}`;
}

/**
 * The desktop-driving core: enough to run the observe → decide → act loop, and
 * nothing else.
 *
 * cua-driver 0.17.0 advertises **54** tools. Registering all of them would put 54
 * JSON schemas into pi's system prompt on every request — expensive, and it
 * crowds the model's tool choice with things a coding-agent session does not
 * need (browser driving, trajectory recording, cursor theming, daemon config).
 * Note there is no `capture` tool: a screenshot arrives from `get_desktop_state`
 * / `get_window_state`, which is exactly why tools are discovered rather than
 * hardcoded.
 */
export const DEFAULT_TOOLS: readonly string[] = [
  // observe
  "list_apps",
  "list_windows",
  "get_desktop_state",
  "get_window_state",
  "get_accessibility_tree",
  "get_screen_size",
  "verify_state",
  // act
  "click",
  "double_click",
  "right_click",
  "drag",
  "type_text",
  "press_key",
  "hotkey",
  "scroll",
  "set_value",
  "invoke_menu",
  "move_cursor",
  // windows & apps
  "launch_app",
  "bring_to_front",
  "set_window_frame",
  // data in/out
  "clipboard_read",
  "clipboard_write",
  // triage
  "health_report",
  "check_permissions",
];

/**
 * Which of the driver's advertised tools to register, intersected with what it
 * actually offers so a stale name is dropped rather than registered as a tool
 * that cannot be called.
 *
 * If the intersection is empty the driver's own roster is used: a future release
 * that renames everything should degrade to "more tools than ideal", never to
 * "silently no computer use".
 */
export function selectTools(advertised: string[], env: Record<string, string | undefined>): string[] {
  const raw = env.MAKIT_COMPUTER_USE_TOOLS?.trim();
  if (raw === "all") return [...advertised];
  const wanted = raw
    ? raw.split(",").map((s) => s.trim()).filter(Boolean)
    : DEFAULT_TOOLS;
  const picked = advertised.filter((name) => wanted.includes(name)).sort();
  return picked.length > 0 ? picked : [...advertised];
}
