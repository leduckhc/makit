/**
 * MirrorAdapter — bridges a **real `pi` TUI** running in a terminal-multiplexer
 * pane to a pino session, so the phone sees it as normal chat (World B).
 *
 *   read  (terminal → phone): tail the pi session `.jsonl` the TUI writes and
 *                             map new records to AdapterEvents via recordToEvents.
 *   write (phone → terminal): inject the phone's text into the TUI pane with
 *                             send-text + Enter (reusing the pane bridge writer).
 *
 * No second pi process is spawned — the TUI stays the single writer of the
 * session file, so there's no double-writer corruption. The phone gets
 * per-message granularity (the file holds final messages, not live token
 * deltas), which is the accepted trade-off for keeping the real TUI.
 */
import { EventEmitter } from "node:events";
import { statSync, readSync, openSync, closeSync } from "node:fs";
import type { AgentAdapter, AdapterEvent, SpawnOpts, UserInput } from "./adapter.js";
import type { PaneReader } from "../pane/bridge.js";
import { recordToEvents } from "../pi-sessions.js";

/** Just the write half of a pane transport. */
export type PaneWriter = Pick<PaneReader, "sendText" | "sendKeys">;

export class MirrorAdapter extends EventEmitter implements AgentAdapter {
  readonly agent = "pi";

  private offset = 0; // bytes of the session file already consumed
  private carry = ""; // partial trailing line between reads
  private timer?: ReturnType<typeof setInterval>;

  constructor(
    private readonly sessionPath: string,
    private readonly paneTarget: string,
    private readonly writer: PaneWriter,
    private readonly pollMs = 300,
  ) {
    super();
  }

  async start(_opts: SpawnOpts): Promise<void> {
    this.emit("status", "idle");
    this.poll(); // emit existing history immediately
    this.timer = setInterval(() => this.poll(), this.pollMs);
    this.timer.unref?.();
  }

  /** Phone → terminal: type the message into the TUI and press Enter. */
  async send(input: UserInput): Promise<void> {
    this.emit("status", "running");
    await this.writer.sendText(this.paneTarget, input.text);
    await this.writer.sendKeys(this.paneTarget, ["Enter"]);
  }

  async cancel(): Promise<void> {
    // Best-effort interrupt of the running turn in the TUI.
    await this.writer.sendKeys(this.paneTarget, ["Escape"]);
    this.emit("status", "idle");
  }

  async kill(): Promise<void> {
    // Stop mirroring only — never kill the user's TUI.
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
    this.emit("exit", null);
  }

  /** Read any newly-appended records and emit their events. Public for tests. */
  poll(): void {
    let size: number;
    try {
      size = statSync(this.sessionPath).size;
    } catch {
      return; // file not there yet — try next tick
    }
    if (size < this.offset) {
      // File truncated/rotated — restart from the top.
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
    this.carry = lines.pop() ?? ""; // last item is a partial line (or "")
    for (const line of lines) {
      if (!line.trim()) continue;
      let o: unknown;
      try {
        o = JSON.parse(line);
      } catch {
        continue; // ignore malformed / half-written lines
      }
      for (const ev of recordToEvents(o)) {
        this.emit("event", ev satisfies AdapterEvent);
        // A completed assistant message means the turn is idle again.
        if (ev.kind === "agent.message") this.emit("status", "idle");
      }
    }
  }
}
