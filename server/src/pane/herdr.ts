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
