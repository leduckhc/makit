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

/**
 * Default cap on a single unterminated stdout frame. A misbehaving agent that
 * never emits an LF must not grow `buf` unbounded and OOM the daemon. Past this
 * cap the in-progress frame is dropped and we resync at the next LF. A few MB
 * is far larger than any legitimate JSON-RPC line.
 */
/**
 * Cap on a single stdout frame from an agent child, measured in JS string
 * length (UTF-16 code units — identical to bytes for the ASCII JSON-RPC frames
 * this guards, and the right order of magnitude otherwise).
 *
 * Sized for **media**, not prose: an ACP `tool_call_update` that completes an
 * image-returning tool carries the bytes base64-encoded inside one JSON line
 * (`rawOutput.content[] {type:"image",data}` — see the pi-acp wire probe in
 * SPEC-22), so a multi-MB screenshot is a *legitimate* frame. At the old 4 MB
 * cap such a frame was dropped, which lost the terminal `status:"completed"`
 * with it and left the tool card spinning forever.
 *
 * Still bounded so a runaway child can't OOM the daemon.
 */
const DEFAULT_MAX_FRAME_BYTES = 32 * 1024 * 1024;

/**
 * How long a child gets to honour SIGTERM before `dispose()` escalates to
 * SIGKILL. Long enough for an agent to flush a final frame and unwind its own
 * children, short enough that closing a session feels immediate.
 */
const DEFAULT_KILL_GRACE_MS = 3000;

/** Invoke each listener defensively — a throwing consumer must never escape
 *  into a stream/exit event handler and take the whole daemon down. */
function safeInvoke<T extends unknown[]>(
  label: string,
  what: string,
  cbs: Array<(...args: T) => void>,
  ...args: T
): void {
  for (const cb of cbs) {
    try {
      cb(...args);
    } catch (e) {
      process.stderr.write(`[${label}] ${what} listener threw: ${(e as Error).message}\n`);
    }
  }
}

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
  /**
   * Cap on a single stdout frame (JS string length). Defaults to
   * {@link DEFAULT_MAX_FRAME_BYTES}. A frame that exceeds this is dropped —
   * mid-frame the buffer resyncs at the next LF — so a runaway child can't OOM
   * the daemon.
   */
  maxFrameBytes?: number;
  /**
   * Grace period between the SIGTERM and the SIGKILL that `dispose()` sends.
   * Defaults to {@link DEFAULT_KILL_GRACE_MS}; tests shorten it.
   */
  killGraceMs?: number;
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
  /**
   * The OS pid of the spawned child, or `undefined` when the spawn faulted
   * (Node leaves `child.pid` undefined on a failed spawn). Surfaced so the
   * metrics collector can attribute a whole process tree to its root pid
   * (SPEC-37). Propagated honestly — never coerced to 0, since 0 is
   * indistinguishable from a genuinely idle agent (decision 11).
   */
  readonly pid: number | undefined;
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
  /**
   * Register a stdout-end listener. Fires exactly once, after every buffered
   * stdout line (including a final unterminated one) has been delivered to
   * `onLine` listeners. This is the correct "no more lines will ever arrive"
   * signal: the child `'exit'` event can fire while stdio is still open, so
   * closing a consumer on `onExit` can drop the tail of the agent's output.
   * A spawn fault (child `'error'`) or stdout close also settles it, so it
   * always fires eventually. Late registrants are replayed.
   */
  onStreamEnd(cb: () => void): void;
  /** Terminate the child: SIGTERM, then SIGKILL if it outlives the grace
   *  period. Safe to call repeatedly — escalation is scheduled at most once. */
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
  // Pending SIGTERM→SIGKILL escalation, cleared the moment the child settles.
  const graceMs = opts.killGraceMs ?? DEFAULT_KILL_GRACE_MS;
  let killTimer: ReturnType<typeof setTimeout> | undefined;
  const settle = (info: ChildExitInfo) => {
    if (settled) return;
    settled = true;
    // The child is gone; a queued SIGKILL now has no target (and its pid may be
    // recycled), so drop it.
    if (killTimer) {
      clearTimeout(killTimer);
      killTimer = undefined;
    }
    bufferedInfo = info;
    safeInvoke(opts.label, "exit", exitCbs, info.code, info);
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
  const maxFrameBytes = opts.maxFrameBytes ?? DEFAULT_MAX_FRAME_BYTES;
  let buf = "";
  // Set once an oversized frame is seen: swallow bytes until the next LF so we
  // resync on a fresh frame rather than delivering a truncated one.
  let dropUntilNewline = false;
  child.stdout?.setEncoding?.("utf8");
  child.stdout?.on("data", (chunk: string | Buffer) => {
    buf += typeof chunk === "string" ? chunk : chunk.toString("utf8");
    let i: number;
    while ((i = buf.indexOf("\n")) !== -1) {
      let line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      if (dropUntilNewline) {
        // We were mid-drop; this LF ends the oversized frame — resync.
        dropUntilNewline = false;
        continue;
      }
      if (line.endsWith("\r")) line = line.slice(0, -1);
      // Enforce the cap on complete frames too. Checking only the pending
      // buffer (below) let a line through when its newline happened to arrive
      // in the same chunk that crossed the limit.
      if (line.length > maxFrameBytes) {
        process.stderr.write(
          `[${opts.label}] dropping oversized stdout frame (> ${maxFrameBytes} chars)\n`,
        );
        continue;
      }
      safeInvoke(opts.label, "line", lineCbs, line);
    }
    // No LF yet and the pending frame is over the cap: drop it (and keep
    // dropping until the next LF) so `buf` can't grow without bound.
    if (buf.length > maxFrameBytes) {
      process.stderr.write(
        `[${opts.label}] dropping oversized stdout frame (> ${maxFrameBytes} bytes, no newline)\n`,
      );
      buf = "";
      dropUntilNewline = true;
    }
  });
  // Deliver a final unterminated line. Idempotent (clears `buf`), so it can
  // run from every completion path without double-delivering.
  const flushPendingLine = () => {
    if (buf.length > 0 && !dropUntilNewline) {
      const line = buf;
      buf = "";
      safeInvoke(opts.label, "line", lineCbs, line);
    }
  };

  // ---- stream end: flush the pending line, then settle once ---------------
  const streamEndCbs: Array<() => void> = [];
  let streamEnded = false;
  const settleStreamEnd = () => {
    if (streamEnded) return;
    streamEnded = true;
    flushPendingLine();
    safeInvoke(opts.label, "stream-end", streamEndCbs);
  };
  // 'end' is the primary signal (all buffered data delivered); 'close' and the
  // child 'error' fault are backstops for streams that are destroyed without
  // ever ending (e.g. a failed spawn), so consumers are never left hanging.
  // Every path flushes before settling.
  child.stdout?.on("end", settleStreamEnd);
  child.stdout?.on("close", settleStreamEnd);
  child.on("error", settleStreamEnd);

  return {
    pid: child.pid,
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
      if (settled && bufferedInfo) safeInvoke(opts.label, "exit", [cb], bufferedInfo.code, bufferedInfo); // replay
    },
    onStreamEnd: (cb) => {
      streamEndCbs.push(cb);
      if (streamEnded) safeInvoke(opts.label, "stream-end", [cb]); // replay
    },
    dispose: () => {
      // Already reaped by the OS — nothing to signal, and SIGKILLing a pid that
      // has been recycled would hit an unrelated process.
      if (settled) return;
      try {
        child.kill("SIGTERM");
      } catch {
        /* ignore */
      }
      // Escalate once. An agent that ignores SIGTERM (or is wedged mid-turn)
      // would otherwise stay resident indefinitely, holding its whole RSS.
      if (killTimer) return;
      killTimer = setTimeout(() => {
        killTimer = undefined;
        if (settled) return;
        process.stderr.write(
          `[${opts.label}] did not exit ${graceMs}ms after SIGTERM — sending SIGKILL\n`,
        );
        try {
          child.kill("SIGKILL");
        } catch {
          /* ignore */
        }
      }, graceMs);
      // Never hold the event loop open just to escalate a kill.
      killTimer.unref?.();
    },
  };
}
