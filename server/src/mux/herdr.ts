/**
 * herdr multiplexer adapter — shells out to the herdr CLI (SPEC-04).
 * Exec is injected for testability; no pino-session knowledge here.
 */

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import {
  MuxError,
  type MultiplexerAdapter,
  type PaneHandle,
  type SpawnPaneOpts,
} from "./adapter.js";

const defaultExec = promisify(execFile);

export type ExecFn = (
  cmd: string,
  args: string[],
) => Promise<{ stdout: string; stderr: string }>;

export interface HerdrAdapterDeps {
  exec?: ExecFn;
  /** Anchor pane id or workspace for splits. */
  anchor: string;
}

const MUX = "herdr";

/** Pure parser for `herdr pane split` JSON. */
export function parseSplitPaneId(stdout: string): string {
  let o: unknown;
  try {
    o = JSON.parse(stdout);
  } catch {
    throw new MuxError(MUX, "split returned non-JSON output");
  }
  const paneId = (o as { result?: { pane?: { pane_id?: unknown } } })?.result
    ?.pane?.pane_id;
  if (typeof paneId !== "string" || paneId.length === 0) {
    throw new MuxError(MUX, "split response missing pane_id");
  }
  return paneId;
}

/** Pure parser for `herdr pane list` JSON. Never throws. */
export function parsePaneList(stdout: string): string[] {
  let o: unknown;
  try {
    o = JSON.parse(stdout);
  } catch {
    return [];
  }
  const panes = (o as { result?: { panes?: unknown } })?.result?.panes;
  if (!Array.isArray(panes)) return [];
  return panes
    .map((p) => (p as { pane_id?: unknown })?.pane_id)
    .filter((id): id is string => typeof id === "string" && id.length > 0);
}

export class HerdrAdapter implements MultiplexerAdapter {
  readonly name = MUX;
  private readonly exec: ExecFn;
  private readonly anchor: string;

  constructor(deps: HerdrAdapterDeps) {
    this.exec = deps.exec ?? defaultExec;
    this.anchor = deps.anchor;
  }

  async isAvailable(): Promise<boolean> {
    try {
      const { stdout } = await this.exec(MUX, ["pane", "list"]);
      return parsePaneList(stdout).includes(this.anchor);
    } catch {
      return false;
    }
  }

  async spawnPane(opts: SpawnPaneOpts): Promise<PaneHandle> {
    const splitArgs = [
      "pane",
      "split",
      this.anchor,
      "--direction",
      "down",
      "--cwd",
      opts.cwd,
    ];
    if (opts.focus !== true) splitArgs.push("--no-focus");

    let stdout: string;
    try {
      ({ stdout } = await this.exec(MUX, splitArgs));
    } catch (e) {
      throw new MuxError(MUX, "pane split failed", e);
    }

    const paneId = parseSplitPaneId(stdout);
    const handle: PaneHandle = { mux: MUX, paneId };

    try {
      await this.exec(MUX, ["pane", "run", paneId, opts.command]);
    } catch (e) {
      await this.closePane(handle);
      throw new MuxError(MUX, "pane run failed", e);
    }

    if (opts.label) {
      try {
        await this.setLabel(handle, opts.label);
      } catch {
        // Best-effort relabel — pane is already running.
      }
    }
    return handle;
  }

  async setLabel(handle: PaneHandle, label: string): Promise<void> {
    try {
      await this.exec(MUX, ["pane", "rename", handle.paneId, label]);
    } catch (e) {
      throw new MuxError(MUX, "pane rename failed", e);
    }
  }

  async closePane(handle: PaneHandle): Promise<void> {
    try {
      await this.exec(MUX, ["pane", "close", handle.paneId]);
    } catch {
      // Idempotent — pane may already be gone.
    }
  }

  async paneExists(handle: PaneHandle): Promise<boolean> {
    try {
      const { stdout } = await this.exec(MUX, ["pane", "list"]);
      return parsePaneList(stdout).includes(handle.paneId);
    } catch {
      return false;
    }
  }
}
