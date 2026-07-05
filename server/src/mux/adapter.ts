/** Pluggable multiplexer adapter types (SPEC-04). Pure mechanism — no session knowledge. */

export interface PaneHandle {
  readonly mux: string;
  readonly paneId: string;
}

export interface SpawnPaneOpts {
  cwd: string;
  command: string;
  label?: string;
  /** Default false — background/unfocused pane. */
  focus?: boolean;
}

export interface MultiplexerAdapter {
  readonly name: string;
  isAvailable(): Promise<boolean>;
  spawnPane(opts: SpawnPaneOpts): Promise<PaneHandle>;
  /** Best-effort relabel. Optional — muxes without rename support omit this.
   *  SPEC-05 callers should use `adapter.setLabel?.(...)` for title updates. */
  setLabel?(handle: PaneHandle, label: string): Promise<void>;
  closePane(handle: PaneHandle): Promise<void>;
  paneExists(handle: PaneHandle): Promise<boolean>;
}

export class MuxError extends Error {
  readonly mux: string;
  readonly cause?: unknown;

  constructor(mux: string, message: string, cause?: unknown) {
    super(`[${mux}] ${message}`);
    this.name = "MuxError";
    this.mux = mux;
    this.cause = cause;
  }
}
