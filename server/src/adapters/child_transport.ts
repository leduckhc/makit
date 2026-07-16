/**
 * child_transport — the ONE subprocess line-transport shared by every
 * subprocess-backed adapter (pi, acp, codex).
 *
 * It owns the transport-level invariant the three adapters used to each
 * re-implement: *a bad agent must never kill the daemon, and stdout is
 * LF-delimited JSON*. Concretely it centralizes:
 *
 *   - piped-stdio spawn
 *   - prefixed stderr forwarding (+ a rolling tail for diagnostics)
 *   - the "settle-once, buffer the exit code until `onExit` registers" dance
 *   - swallowing async `'error'` on the child / stdin / stdout / stderr (Node
 *     re-throws an unlistened `'error'` as an uncaught exception — that would
 *     crash the whole daemon and take every other session down with it)
 *   - an LF-only line splitter (we MUST split on `\n` only — `readline` also
 *     splits on U+2028/U+2029 which are valid inside JSON strings)
 *
 * Adapters keep only their protocol-specific concerns on top of this.
 */

import { spawn as nodeSpawn, type ChildProcess } from "node:child_process";

/** Max bytes of stderr kept for the exit diagnostic tail. */
const STDERR_TAIL_BYTES = 8192;

export interface SpawnLineOptions {
  command: string;
  args?: string[];
  cwd: string;
  /** Extra env merged over `process.env`. */
  env?: Record<string, string>;
  /** Log/stderr prefix, e.g. "pi" or "codex-app-server". */
  label: string;
  /** Injectable spawn (tests provide a fake); defaults to node's child_process. */
  spawn?: typeof nodeSpawn;
}

/** Extra context handed to `onExit` listeners (adapters may ignore it). */
export interface ChildExitInfo {
  code: number | null;
  signal: NodeJS.Signals | null;
  /** Set when the process faulted / failed to spawn (a child `'error'` event). */
  error?: Error;
  /** Rolling tail of stderr (last ~8KB) captured for diagnostics. */
  stderrTail: string;
}

/**
 * A supervised subprocess exposing an LF-delimited-JSON line transport.
 * `CodexTransport` is a direct alias of this shape; `AcpTransport` wraps it.
 */
export interface ChildLineTransport {
  /** Send one raw line (a trailing newline is appended). */
  send(line: string): void;
  /** Register a listener for each inbound LF-delimited line (multiple allowed). */
  onLine(cb: (line: string) => void): void;
  /**
   * Register an exit listener. Fires exactly once with the exit code; a
   * spawn/process fault settles with `code = null`. Late registrants are
   * replayed the buffered result. `info` carries the fault + stderr tail for
   * adapters that surface richer diagnostics.
   */
  onExit(cb: (code: number | null, info: ChildExitInfo) => void): void;
  /** Terminate the child (SIGTERM); safe to call repeatedly. */
  dispose(): void;
}

export function spawnLineProcess(opts: SpawnLineOptions): ChildLineTransport {
  const spawn = opts.spawn ?? nodeSpawn;
  const child: ChildProcess = spawn(opts.command, opts.args ?? [], {
    cwd: opts.cwd,
    env: { ...process.env, ...(opts.env ?? {}) },
    stdio: ["pipe", "pipe", "pipe"],
  });

  // ---- stderr: forward with a prefix + keep a rolling tail ----------------
  let stderrTail = "";
  child.stderr?.on("data", (chunk: Buffer | string) => {
    const s = typeof chunk === "string" ? chunk : chunk.toString("utf8");
    stderrTail += s;
    if (stderrTail.length > STDERR_TAIL_BYTES) stderrTail = stderrTail.slice(-STDERR_TAIL_BYTES);
    process.stderr.write(`[${opts.label}] ${s}`);
  });

  // ---- exit / fault: settle once, buffer until onExit registers -----------
  const exitCbs: Array<(code: number | null, info: ChildExitInfo) => void> = [];
  let settled = false;
  let bufferedInfo: ChildExitInfo | undefined;
  const settle = (info: ChildExitInfo) => {
    if (settled) return;
    settled = true;
    bufferedInfo = info;
    for (const cb of exitCbs) cb(info.code, info);
  };
  child.on("exit", (code, signal) => settle({ code, signal, stderrTail }));
  child.on("error", (err: Error) => {
    process.stderr.write(`[${opts.label}] process error: ${err.message}\n`);
    settle({ code: null, signal: null, error: err, stderrTail });
  });

  // Writing to a dead child's stdin surfaces as an async 'error' (EPIPE); a
  // read fault on stdout/stderr likewise. None of these must become an
  // unlistened 'error' — the child 'error'/'exit' handlers own the real state
  // transition, so here we only log and swallow.
  child.stdin?.on("error", (e: Error) => process.stderr.write(`[${opts.label}] stdin error: ${e.message}\n`));
  child.stdout?.on("error", (e: Error) => process.stderr.write(`[${opts.label}] stdout error: ${e.message}\n`));
  child.stderr?.on("error", (e: Error) => process.stderr.write(`[${opts.label}] stderr error: ${e.message}\n`));

  // ---- stdout: LF-only line splitting -------------------------------------
  const lineCbs: Array<(line: string) => void> = [];
  let buf = "";
  child.stdout?.setEncoding?.("utf8");
  child.stdout?.on("data", (chunk: string | Buffer) => {
    buf += typeof chunk === "string" ? chunk : chunk.toString("utf8");
    let i: number;
    while ((i = buf.indexOf("\n")) !== -1) {
      let line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      if (line.endsWith("\r")) line = line.slice(0, -1);
      for (const cb of lineCbs) cb(line);
    }
  });
  child.stdout?.on("end", () => {
    if (buf.length > 0) for (const cb of lineCbs) cb(buf);
  });

  return {
    send: (line: string) => {
      const stdin = child.stdin;
      if (!stdin || stdin.destroyed) return;
      try {
        stdin.write(line + "\n");
      } catch (e) {
        // Torn down between the guard and the write; the stdin 'error' listener
        // + exit handler own the teardown. Never throw synchronously here.
        process.stderr.write(`[${opts.label}] stdin write failed: ${(e as Error).message}\n`);
      }
    },
    onLine: (cb) => {
      lineCbs.push(cb);
    },
    onExit: (cb) => {
      exitCbs.push(cb);
      if (settled && bufferedInfo) cb(bufferedInfo.code, bufferedInfo); // replay
    },
    dispose: () => {
      try {
        child.kill("SIGTERM");
      } catch {
        /* ignore */
      }
    },
  };
}
