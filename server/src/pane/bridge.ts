/**
 * PaneBridge — mirrors a terminal-multiplexer pane over the makit WS server.
 *
 * herdr (and tmux) already solve multi-client attach + input injection into a
 * live process, so instead of makit spawning pi, it can bridge a pane that is
 * *already* running `pi` (or anything): poll the pane's rendered screen and
 * fan it to subscribers, and inject text/keys back. This is the "attach to the
 * real pi TUI via the multiplexer" path — no pi daemon required.
 *
 * herdr has no push/stream, so we poll `pane read` on an interval and only emit
 * when the rendered screen changed. Pollers are ref-counted per target so many
 * clients share one poll loop and it stops when the last subscriber leaves.
 */

/** The multiplexer operations the bridge needs. Swappable for tmux/tests. */
export interface PaneReader {
  /** Rendered screen of the pane (ANSI). */
  read(target: string): Promise<string>;
  /** Type text into the pane (no Enter). */
  sendText(target: string, text: string): Promise<void>;
  /** Press keys in the pane (e.g. ["Enter"]). */
  sendKeys(target: string, keys: string[]): Promise<void>;
}

export type FrameSink = (target: string, data: string) => void;

interface PaneState {
  refs: number;
  last: string;
  timer?: ReturnType<typeof setInterval>;
}

export class PaneBridge {
  private readonly panes = new Map<string, PaneState>();

  constructor(
    private readonly reader: PaneReader,
    private readonly sink: FrameSink,
    private readonly intervalMs = 400,
  ) {}

  /** Start (or ref) mirroring a pane. */
  attach(target: string): void {
    const existing = this.panes.get(target);
    if (existing) {
      existing.refs++;
      return;
    }
    const st: PaneState = { refs: 1, last: "" };
    this.panes.set(target, st);
    st.timer = setInterval(() => void this.pollOnce(target), this.intervalMs);
    // Don't keep the process alive on the poller alone.
    st.timer.unref?.();
    void this.pollOnce(target); // emit an initial frame promptly
  }

  /** Drop one ref; stop polling when the last subscriber leaves. */
  detach(target: string): void {
    const st = this.panes.get(target);
    if (!st) return;
    if (--st.refs > 0) return;
    if (st.timer) clearInterval(st.timer);
    this.panes.delete(target);
  }

  /** Read the pane once; emit a frame only if the screen changed. */
  async pollOnce(target: string): Promise<void> {
    const st = this.panes.get(target);
    if (!st) return;
    let data: string;
    try {
      data = await this.reader.read(target);
    } catch {
      return; // transient herdr error — try again next tick
    }
    if (!this.panes.has(target)) return; // detached while awaiting
    if (data !== st.last) {
      st.last = data;
      this.sink(target, data);
    }
  }

  input(target: string, text: string): Promise<void> {
    return this.reader.sendText(target, text);
  }

  keys(target: string, keys: string[]): Promise<void> {
    return this.reader.sendKeys(target, keys);
  }
}
