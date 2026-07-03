/**
 * IngestAdapter — a session whose events are PUSHED IN by an external
 * `pino-mirror` pi extension (World D), rather than produced by a pino-spawned
 * process. The extension, loaded into the user's real `pi` (TUI or otherwise),
 * forwards pi's own agent events here and receives the phone's prompts back.
 *
 *   read  (pi → phone): extension calls ingestEvent()/ingestStatus() with the
 *                       same AdapterEvent shapes PiAdapter emits → full-fidelity
 *                       streaming chat on the phone.
 *   write (phone → pi): send() forwards the phone's text to `onPrompt`, which
 *                       the server relays to the extension → pi.sendUserMessage.
 *
 * No process is spawned and no file is tailed.
 */
import { EventEmitter } from "node:events";
import type { AgentAdapter, AdapterEvent, SpawnOpts, UserInput } from "./adapter.js";

export class IngestAdapter extends EventEmitter implements AgentAdapter {
  readonly agent = "pi";
  private alive = true;

  /** @param onPrompt relay the phone's message back to the hosting extension. */
  constructor(private readonly onPrompt: (text: string) => void) {
    super();
  }

  async start(_opts: SpawnOpts): Promise<void> {
    this.emit("status", "idle");
  }

  /** Phone → pi: relay to the extension, which calls pi.sendUserMessage. */
  async send(input: UserInput): Promise<void> {
    if (this.alive) this.onPrompt(input.text);
  }

  async cancel(): Promise<void> {
    // Interrupt is best-effort; the extension may map this later.
  }

  async kill(): Promise<void> {
    this.alive = false;
    this.emit("exit", null);
  }

  // ---- push API used by the server's host.* command handlers -------------

  /** Emit one agent event pushed from the extension. */
  ingestEvent(e: AdapterEvent): void {
    if (this.alive) this.emit("event", e);
  }

  /** Update the running/idle status pushed from the extension. */
  ingestStatus(status: "idle" | "running"): void {
    if (this.alive) this.emit("status", status);
  }
}
