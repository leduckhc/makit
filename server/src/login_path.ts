/**
 * Login-shell PATH recovery for the long-running `serve` process.
 *
 * A macOS app launched from Finder (or `open`) inherits launchd's environment,
 * whose PATH is exactly `/usr/bin:/bin:/usr/sbin:/sbin` — none of the dirs a
 * user's agent binaries actually live in. The daemon the desktop app spawns
 * inherits that too, so every agent spawn fails with `spawn pi-acp ENOENT`,
 * which surfaces to the user as a dead session ("not live after a server
 * restart") or a failed promotion. A daemon started from a terminal has the
 * user's full PATH and works — which is exactly why this only bites GUI launches.
 *
 * Fix at the single point that matters: on startup, when PATH looks like
 * launchd's, ask the user's login shell what PATH really is and adopt it. Every
 * agent spawn merges over `process.env` (see `child_transport`), so repairing
 * `process.env.PATH` once repairs all of them.
 */

import { execFileSync } from "node:child_process";
import { delimiter } from "node:path";

import { log } from "./log.js";

/**
 * The dirs launchd hands a GUI-launched process. A PATH built only from these
 * cannot contain user-installed tooling, so it is treated as "not the user's
 * real PATH". A single entry outside this set means someone set PATH
 * deliberately and we must not second-guess it.
 */
const SYSTEM_ONLY_DIRS = new Set(["/usr/bin", "/bin", "/usr/sbin", "/sbin"]);

/** Delimit the echoed PATH so rc-file banners/noise can't be mistaken for it. */
const MARKER_BEGIN = "__MAKIT_PATH_BEGIN__";
const MARKER_END = "__MAKIT_PATH_END__";

/** Cap on the login shell probe — a hanging rc file must not block startup. */
const PROBE_TIMEOUT_MS = 3000;

export interface LoginPathOptions {
  /** Environment to read/repair (defaults to `process.env`). */
  env?: NodeJS.ProcessEnv;
  /** Injectable shell runner returning stdout; defaults to `execFileSync`. */
  run?: (shell: string, args: string[]) => string;
}

/** Whether `path` carries nothing but launchd's system dirs (or is absent). */
export function isMinimalPath(path: string | undefined): boolean {
  const dirs = (path ?? "")
    .split(delimiter)
    .map((d) => d.trim().replace(/\/+$/, ""))
    .filter(Boolean);
  if (dirs.length === 0) return true;
  return dirs.every((d) => SYSTEM_ONLY_DIRS.has(d));
}

/**
 * The PATH the user's login shell reports, or `undefined` when it cannot be
 * determined. Runs an **interactive** login shell (`-ilc`): on macOS+zsh the
 * user's PATH edits typically live in `~/.zshrc`, which a non-interactive shell
 * never sources.
 */
export function loginShellPath(opts: LoginPathOptions = {}): string | undefined {
  const env = opts.env ?? process.env;
  const shell = env.SHELL;
  if (!shell) return undefined;
  const run =
    opts.run ??
    ((cmd: string, args: string[]) =>
      execFileSync(cmd, args, {
        encoding: "utf8",
        timeout: PROBE_TIMEOUT_MS,
        // An rc file that reads stdin, or writes to stderr, must not hang or
        // pollute the probe.
        stdio: ["ignore", "pipe", "ignore"],
      }));
  try {
    const out = run(shell, ["-ilc", `printf '${MARKER_BEGIN}%s${MARKER_END}' "$PATH"`]);
    const start = out.indexOf(MARKER_BEGIN);
    const end = out.indexOf(MARKER_END, start + 1);
    if (start < 0 || end < 0) return undefined;
    const path = out.slice(start + MARKER_BEGIN.length, end).trim();
    return path.length > 0 ? path : undefined;
  } catch {
    // No usable shell, a timeout, or a non-zero exit: leave PATH as-is.
    return undefined;
  }
}

/**
 * Adopt the login shell's PATH when the current one is launchd-minimal.
 * Returns whether PATH was replaced. No-op (and no shell spawned) when PATH
 * already looks real, or when the shell reports an equally minimal PATH.
 */
export function adoptLoginShellPathIfMinimal(opts: LoginPathOptions = {}): boolean {
  const env = opts.env ?? process.env;
  if (!isMinimalPath(env.PATH)) return false;
  const resolved = loginShellPath(opts);
  if (!resolved || isMinimalPath(resolved)) return false;
  env.PATH = resolved;
  log.warn(
    `[makit] PATH was launchd-minimal (GUI launch) — adopted ${env.SHELL}'s PATH so agent binaries resolve`,
  );
  return true;
}
