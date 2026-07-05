/** Multiplexer registry — name → adapter (SPEC-04). */

import { loadMuxConfig } from "./config.js";
import { HerdrAdapter, type ExecFn } from "./herdr.js";
import type { MultiplexerAdapter } from "./adapter.js";

export interface GetMultiplexerOpts {
  /** Override exec for tests or custom runners. */
  exec?: ExecFn;
}

const adapters: Record<
  string,
  (anchor: string, exec?: ExecFn) => MultiplexerAdapter
> = {
  herdr: (anchor, exec) => new HerdrAdapter({ anchor, exec }),
};

/** Resolve a multiplexer by name. Env/config default when name omitted. */
export function getMultiplexer(
  name?: string,
  opts?: GetMultiplexerOpts,
): MultiplexerAdapter | undefined {
  const cfg = loadMuxConfig();
  const resolved = (name ?? cfg.mux).trim().toLowerCase();
  if (resolved === "off" || resolved === "") return undefined;
  const factory = adapters[resolved];
  return factory?.(cfg.anchor, opts?.exec);
}
