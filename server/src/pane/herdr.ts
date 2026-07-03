/**
 * herdr-backed {@link PaneReader}. Shells out to the `herdr` CLI, which talks
 * to the running herdr instance over its local socket. Only usable when the
 * server runs inside herdr (HERDR_ENV=1).
 *
 * Screen source is `visible` (current viewport) with `--format ansi` so the
 * mirror preserves colours/attributes of the real pi TUI.
 */
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { PaneReader } from "./bridge.js";

const pexec = promisify(execFile);

/** Rows to capture per frame — a phone/terminal viewport is small anyway. */
const VISIBLE_LINES = 60;

export const herdrReader: PaneReader = {
  async read(target: string): Promise<string> {
    const { stdout } = await pexec("herdr", [
      "pane",
      "read",
      target,
      "--source",
      "visible",
      "--lines",
      String(VISIBLE_LINES),
      "--format",
      "ansi",
    ]);
    return stdout;
  },
  async sendText(target: string, text: string): Promise<void> {
    await pexec("herdr", ["pane", "send-text", target, text]);
  },
  async sendKeys(target: string, keys: string[]): Promise<void> {
    if (keys.length === 0) return;
    await pexec("herdr", ["pane", "send-keys", target, ...keys]);
  },
};

/** What we can learn about a pane's running agent from herdr. */
export interface PaneAgentInfo {
  /** The agent's session file, when herdr reports one (kind: "path"). */
  sessionPath?: string;
  /** The pane's working directory. */
  cwd?: string;
  /** Detected agent label, e.g. "pi". */
  agent?: string;
}

/** Pure parser for `herdr pane get` JSON. Never throws. */
export function parsePaneInfo(stdout: string): PaneAgentInfo {
  let o: any;
  try {
    o = JSON.parse(stdout);
  } catch {
    return {};
  }
  const pane = o?.result?.pane;
  if (!pane || typeof pane !== "object") return {};
  const sess = pane.agent_session;
  const sessionPath =
    sess && sess.kind === "path" && typeof sess.value === "string"
      ? sess.value
      : undefined;
  return {
    sessionPath,
    cwd: typeof pane.cwd === "string" ? pane.cwd : undefined,
    agent: typeof pane.agent === "string" ? pane.agent : undefined,
  };
}

/** Query herdr for a pane's agent/session info (for `pino mirror` auto-discovery). */
export async function paneAgentInfo(target: string): Promise<PaneAgentInfo> {
  try {
    const { stdout } = await pexec("herdr", ["pane", "get", target]);
    return parsePaneInfo(stdout);
  } catch {
    return {};
  }
}
