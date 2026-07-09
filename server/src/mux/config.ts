/**
 * Multiplexer config — read from ~/.makit/config.json with env overrides.
 * Never throws on bad input; missing/corrupt file degrades to defaults.
 */

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { log } from "../log.js";

export interface MuxConfig {
  /** Active multiplexer name, e.g. "herdr". Env MAKIT_MUX wins. */
  mux: string;
  /** Anchor pane id for new splits. Env MAKIT_MUX_ANCHOR wins. */
  anchor: string;
}

function makitHome(): string {
  return process.env.MAKIT_HOME || join(homedir(), ".makit");
}

export function configFile(): string {
  return process.env.MAKIT_CONFIG_FILE ?? join(makitHome(), "config.json");
}

interface ConfigFileShape {
  mux?: { name?: string; anchor?: string };
}

function readConfigFile(file: string): ConfigFileShape {
  try {
    if (!existsSync(file)) return {};
    const parsed = JSON.parse(readFileSync(file, "utf8")) as unknown;
    if (typeof parsed !== "object" || parsed === null) return {};
    return parsed as ConfigFileShape;
  } catch (e) {
    log.warn(`[makit] failed to read mux config ${file}: ${(e as Error).message}`);
    return {};
  }
}

/** Default anchor label; herdr is unavailable until this resolves to an actual pane id. */
export const DEFAULT_MUX_ANCHOR = "makit";

/** Load mux config. Env vars override file values. */
export function loadMuxConfig(file = configFile()): MuxConfig {
  const fromFile = readConfigFile(file);
  const mux =
    process.env.MAKIT_MUX?.trim() ||
    fromFile.mux?.name?.trim() ||
    "herdr";
  const anchor =
    process.env.MAKIT_MUX_ANCHOR?.trim() ||
    fromFile.mux?.anchor?.trim() ||
    DEFAULT_MUX_ANCHOR;
  return { mux, anchor };
}
