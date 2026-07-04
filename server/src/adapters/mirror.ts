/**
 * MirrorAdapter — bridges a **real `pi` TUI** running in a terminal-multiplexer
 * pane to a pino session, so the phone sees it as normal chat (World B).
 *
 *   read  (terminal → phone): tail the pi session `.jsonl` the TUI writes and
 *                             map new records to AdapterEvents via recordToEvents.
 *   write (phone → terminal): inject the phone's text into the TUI pane with
 *                             send-text + Enter (reusing the pane bridge writer).
 *
 * No second pi process is spawned **for the chat stream** — the TUI stays the
 * single writer of the session file, so there's no double-writer corruption.
 * The phone gets per-message granularity (the file holds final messages, not
 * live token deltas), which is the accepted trade-off for keeping the real TUI.
 *
 * **Slash palette:** see `commands.ts`. When `enableCommands` is called before
 * `start()`, a short-lived `pi --mode rpc --no-session` child is spawned in
 * the project cwd to call `get_commands` and emit `session.commands` once.
 */
import { EventEmitter } from "node:events";
import { statSync, readSync, openSync, closeSync } from "node:fs";
import type { ChildProcessWithoutNullStreams } from "node:child_process";
import type { AgentAdapter, AdapterEvent, SpawnOpts, UserInput } from "./adapter.js";
import type { PaneReader } from "../pane/bridge.js";
import { recordToEvents } from "../pi-sessions.js";
import {
  type CommandsFetcher,
  fetchPiCommands,
  buildCommandsEvent,
} from "./commands.js";

/** Just the write half of a pane transport. */
export type PaneWriter = Pick<PaneReader, "sendText" | "sendKeys">;

/** Re-export so callers/tests can import from one place. */
export type { CommandsFetcher } from "./commands.js";

/**
 * Default production fetcher (for callers that want to pass it in directly):
 * spawns `pi --mode rpc --no-session`, calls `get_commands`. ~1.2s wall time.
 */
export const realCommandsFetcher: CommandsFetcher = (cwd) => fetchPiCommands(cwd).promise;

export class MirrorAdapter extends EventEmitter implements AgentAdapter {
  readonly agent = "pi";

  private offset = 0;
  private carry = "";
  private timer?: ReturnType<typeof setInterval>;
  private commandsChild?: ChildProcessWithoutNullStreams;
  private cwd?: string;
  /** Public so tests can await it; mirrors fire-and-forget at `start()`. */
  fetchCommandsDone?: Promise<void>;

  constructor(
    private readonly sessionPath: string,
    private readonly paneTarget: string,
    private readonly writer: PaneWriter,
    private readonly pollMs = 300,
    private commandsFetcher?: CommandsFetcher,
  ) {
    super();
  }

  /** Opt in to the production real-pi fetcher. Call before `start()`. */
  enableCommands(fetcher: CommandsFetcher = realCommandsFetcher): void {
    this.commandsFetcher = fetcher;
  }

  async start(opts: SpawnOpts): Promise<void> {
    this.cwd = opts.cwd;
    this.emit("status", "idle");
    this.poll();
    this.timer = setInterval(() => this.poll(), this.pollMs);
    this.timer.unref?.();
    if (this.commandsFetcher) {
      this.fetchCommandsDone = this.fetchCommands().catch(() => {/* swallow */});
    }
  }

  async send(input: UserInput): Promise<void> {
    this.emit("status", "running");
    await this.writer.sendText(this.paneTarget, input.text);
    await this.writer.sendKeys(this.paneTarget, ["Enter"]);
  }

  async cancel(): Promise<void> {
    await this.writer.sendKeys(this.paneTarget, ["Escape"]);
    this.emit("status", "idle");
  }

  async kill(): Promise<void> {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
    if (this.commandsChild && !this.commandsChild.killed) {
      try { this.commandsChild.kill("SIGKILL"); } catch { /* already dead */ }
    }
    this.commandsChild = undefined;
    this.emit("exit", null);
  }

  /** Read any newly-appended records and emit their events. Public for tests. */
  poll(): void {
    let size: number;
    try {
      size = statSync(this.sessionPath).size;
    } catch {
      return;
    }
    if (size < this.offset) {
      this.offset = 0;
      this.carry = "";
    }
    if (size === this.offset) return;

    let chunk: string;
    try {
      const fd = openSync(this.sessionPath, "r");
      try {
        const buf = Buffer.alloc(size - this.offset);
        readSync(fd, buf, 0, buf.length, this.offset);
        chunk = buf.toString("utf8");
      } finally {
        closeSync(fd);
      }
    } catch {
      return;
    }
    this.offset = size;

    const lines = (this.carry + chunk).split("\n");
    this.carry = lines.pop() ?? "";
    for (const line of lines) {
      if (!line.trim()) continue;
      let o: unknown;
      try { o = JSON.parse(line); } catch { continue; }
      for (const ev of recordToEvents(o)) {
        this.emit("event", ev satisfies AdapterEvent);
        if (ev.kind === "agent.message") this.emit("status", "idle");
      }
    }
  }

  private async fetchCommands(): Promise<void> {
    const cwd = this.cwd;
    const fetcher = this.commandsFetcher;
    if (!cwd || !fetcher) return;

    // For the real fetcher, track the spawned child so kill() can SIGKILL it.
    if (fetcher === realCommandsFetcher) {
      const handle = fetchPiCommands(cwd);
      this.commandsChild = handle.child;
      try {
        const commands = await handle.promise;
        const ev = buildCommandsEvent(commands);
        if (ev) this.emit("event", ev);
      } catch {
        /* swallow — palette stays empty */
      } finally {
        if (this.commandsChild === handle.child) this.commandsChild = undefined;
      }
      return;
    }

    // Test / injected path: just await and emit.
    const commands = await fetcher(cwd);
    const ev = buildCommandsEvent(commands);
    if (ev) this.emit("event", ev);
  }
}
