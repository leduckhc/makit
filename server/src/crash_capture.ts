/**
 * Process-level crash capture for the long-running `serve` process.
 *
 * Node prints an uncaught error to stderr by default, but registering our own
 * handlers gives a consistent, greppable `[makit]` line in `~/.makit/makit.log`
 * (the daemon captures stderr) and lets `unhandledRejection` be logged without
 * killing the server. Registering an `uncaughtException` listener suppresses
 * Node's default exit, so we re-assert fail-fast explicitly with `exit(1)`:
 * the process is in an unknown state and must not limp on.
 */

import { log } from "./log.js";

export interface CrashCaptureOptions {
  /** Terminate the process (default `process.exit`). Injected for tests. */
  exit?: (code: number) => void;
}

/** Install crash handlers; returns a disposer that removes them. */
export function installProcessCrashHandlers(opts: CrashCaptureOptions = {}): () => void {
  const exit = opts.exit ?? ((code: number) => process.exit(code));

  const onRejection = (reason: unknown): void => {
    log.error(`[makit] unhandledRejection: ${describe(reason)}`);
  };
  const onException = (err: unknown): void => {
    log.error(`[makit] uncaughtException: ${describe(err)}`);
    exit(1);
  };

  process.on("unhandledRejection", onRejection);
  process.on("uncaughtException", onException);

  return () => {
    process.off("unhandledRejection", onRejection);
    process.off("uncaughtException", onException);
  };
}

function describe(e: unknown): string {
  if (e instanceof Error) return `${e.message}\n${e.stack ?? ""}`.trimEnd();
  return String(e);
}
