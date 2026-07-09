/**
 * IngestAdapter — a session whose events are PUSHED IN by an external
 * `makit-mirror` pi extension (World D), rather than produced by a makit-spawned
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
 *
 * **Slash palette:** see `commands.ts`. When `enableCommands` is called before
 * `start()`, a short-lived `pi --mode rpc --no-session` child is spawned in
 * the project cwd to call `get_commands` and emit `session.commands` once.
 */
import { EventEmitter } from "node:events";
import type { ChildProcessWithoutNullStreams } from "node:child_process";
import type { AgentAdapter, AdapterEvent, SpawnOpts, UserInput } from "./adapter.js";
import {
  type CommandsFetcher,
  fetchPiCommands,
  buildCommandsEvent,
} from "./commands.js";

/** Re-export so callers/tests can import from one place. */
export type { CommandsFetcher } from "./commands.js";

/**
 * Default production fetcher: spawns `pi --mode rpc --no-session`, calls
 * `get_commands`. ~1.2s wall time.
 */
export const realCommandsFetcher: CommandsFetcher = (cwd) => fetchPiCommands(cwd).promise;

export class IngestAdapter extends EventEmitter implements AgentAdapter {
  readonly agent = "pi";
  private alive = true;
  private cwd?: string;
  private commandsChild?: ChildProcessWithoutNullStreams;
  /** Public so tests can await it; mirrors fire-and-forget at `start()`. */
  fetchCommandsDone?: Promise<void>;

  /**
   * @param onPrompt relay the phone's message back to the hosting extension.
   * @param commandsFetcher optional test fetcher; production callers use
   *        {@link IngestAdapter.enableCommands} to wire the real pi fetcher.
   */
  constructor(
    private readonly onPrompt: (text: string) => void,
    private commandsFetcher?: CommandsFetcher,
    private readonly onAction?: (
      action: string,
      args?: Record<string, unknown>,
    ) => void,
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
    if (this.commandsFetcher) {
      this.fetchCommandsDone = this.fetchCommands().catch(() => {/* swallow */});
    }
  }

  /** Phone → pi: relay to the extension, which calls pi.sendUserMessage. */
  async send(input: UserInput): Promise<void> {
    if (this.alive) this.onPrompt(input.text);
  }

  /**
   * Phone → pi: relay a built-in control action (e.g. `compact`, `thinking`)
   * to the extension, which invokes the corresponding pi SDK call. Distinct
   * from {@link send} because these aren't user turns — they never reach the
   * LLM as a prompt.
   */
  async sendAction(action: string, args?: Record<string, unknown>): Promise<void> {
    if (this.alive) this.onAction?.(action, args);
  }

  async cancel(): Promise<void> {
    // Interrupt is best-effort; the extension may map this later.
  }

  async kill(): Promise<void> {
    this.alive = false;
    if (this.commandsChild && !this.commandsChild.killed) {
      try { this.commandsChild.kill("SIGKILL"); } catch { /* already dead */ }
    }
    this.commandsChild = undefined;
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
