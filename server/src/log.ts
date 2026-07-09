/**
 * Tiny leveled logger — gated by the `MAKIT_LOG` env var.
 *
 * Levels (low → high): debug < info < warn < error. Messages below the
 * active level are dropped. Default level is `info`; set `MAKIT_LOG=debug`
 * for verbose wire tracing or `MAKIT_LOG=warn` to quieten the dev loop.
 *
 * The level is resolved lazily on every call so tests (and operators) can
 * flip `MAKIT_LOG` at runtime without re-importing the module.
 */

export type LogLevel = "debug" | "info" | "warn" | "error";

const LEVEL_ORDER: Record<LogLevel, number> = {
  debug: 0,
  info: 1,
  warn: 2,
  error: 3,
};

const DEFAULT_LEVEL: LogLevel = "info";

function activeLevel(): LogLevel {
  const raw = (process.env.MAKIT_LOG ?? "").toLowerCase();
  return raw in LEVEL_ORDER ? (raw as LogLevel) : DEFAULT_LEVEL;
}

function enabled(level: LogLevel): boolean {
  return LEVEL_ORDER[level] >= LEVEL_ORDER[activeLevel()];
}

export interface Logger {
  debug(...args: unknown[]): void;
  info(...args: unknown[]): void;
  warn(...args: unknown[]): void;
  error(...args: unknown[]): void;
}

/**
 * Create a logger. All output goes to stderr so it never corrupts any
 * stdout-based protocol stream. `console.error` is used for every level
 * for that reason.
 */
export function createLogger(): Logger {
  const emit = (level: LogLevel, args: unknown[]): void => {
    if (!enabled(level)) return;
    // eslint-disable-next-line no-console
    console.error(...args);
  };
  return {
    debug: (...args) => emit("debug", args),
    info: (...args) => emit("info", args),
    warn: (...args) => emit("warn", args),
    error: (...args) => emit("error", args),
  };
}

/** Shared process-wide logger. */
export const log: Logger = createLogger();
