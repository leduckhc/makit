/**
 * Shared helper for CLI subcommands that require a running makit daemon
 * (SPEC-02).
 *
 * All "thin client" commands (`makit qr`, `makit status`, `makit devices`, …)
 * call `requireDaemon()` first. If the control socket is absent or refuses the
 * connection they get a clean error message (no stack trace) and the process
 * exits 3 — the conventional "service not running" exit code.
 */

import { connectControlClient, type ControlClient } from "../daemon/control-client.js";
import { EXIT_NOT_RUNNING } from "./exit-codes.js";

/** Exit code used by every "daemon not running" error path. */
export { EXIT_NOT_RUNNING };

const NOT_RUNNING_MSG = "makit is not running — start it with 'makit start'";

/**
 * Connect to the running daemon's control socket.
 *
 * On ECONNREFUSED, ENOENT (socket file missing), or any other connection error,
 * prints the standard "not running" message to stderr and exits with code 3.
 * Never throws.
 */
export async function requireDaemon(socketPath: string): Promise<ControlClient> {
  try {
    return await connectControlClient(socketPath);
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code;
    if (code === "ECONNREFUSED" || code === "ENOENT") {
      console.error(NOT_RUNNING_MSG);
    } else {
      console.error(`${NOT_RUNNING_MSG} (${(err as Error).message})`);
    }
    process.exit(EXIT_NOT_RUNNING);
  }
}
