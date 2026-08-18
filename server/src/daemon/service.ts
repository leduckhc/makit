/**
 * Daemon service (SPEC-daemon-control-plane, phase 4).
 *
 * User-controlled background lifecycle for the makit server:
 *   - `start`   — spawn `serve` detached, redirect output to the log, record PID.
 *                 Idempotent: if already running, print status and exit 0.
 *   - `stop`    — SIGTERM the recorded PID (the server's handler shuts down
 *                 gracefully and removes its socket), then remove the PID file.
 *   - `restart` — stop (if running) + start.
 *   - `status`  — query the running daemon over the control socket.
 *   - `logs`    — tail the log file (`-f` to follow).
 *
 * ## Log file policy
 *
 * `~/.makit/makit.log` is **truncated on every `start`** (opened with `"w"`). Log
 * rotation is intentionally out of scope for v1 (SPEC-daemon-control-plane open question): a fresh
 * run starts with a clean log, and operators who want history can copy it aside
 * before starting. Revisit if log volume becomes a problem.
 *
 * All OS-touching collaborators (spawn, kill, control-client connect, log fd)
 * are injected via {@link DaemonDeps} so the orchestration is unit-testable
 * without launching a real process or writing to the real `~/.makit`.
 */

import {
  readFileSync,
  writeFileSync,
  rmSync,
  existsSync,
  mkdirSync,
  chmodSync,
  watch,
} from "node:fs";
import { dirname } from "node:path";
import { MAKIT_HOME_MODE, MAKIT_FILE_MODE } from "./paths.js";
import type { ControlClient } from "./control-client.js";
import type { StatusData } from "./protocol.js";

/** The subset of a spawned child process the daemon depends on. */
export interface SpawnedChild {
  pid?: number;
  unref(): void;
}

/** Serve flags forwarded from `makit start` to the detached `serve` process. */
export interface ServeOptions {
  host: string;
  port: number;
  projects: string[];
  noAuth: boolean;
  advertise: string;
}

export interface DaemonDeps {
  /** Absolute path to the CLI entry file passed as argv[0] to `execPath`. */
  entry: string;
  /** Node binary (`process.execPath`). */
  execPath: string;
  socketPath: string;
  pidPath: string;
  logPath: string;
  /** Where human-facing lines go (stdout in production). */
  out: (line: string) => void;
  spawn: (cmd: string, args: string[], logFd: number) => SpawnedChild;
  /** Open (and truncate) the log file, returning its fd. */
  openLogFd: (path: string) => number;
  kill: (pid: number, signal: NodeJS.Signals) => void;
  isAlive: (pid: number) => boolean;
  connect: (socketPath: string) => Promise<ControlClient>;
  /** Injectable wait (tests pass a no-op); defaults to real setTimeout. */
  sleep?: (ms: number) => Promise<void>;
  /** Max time to wait for a freshly-spawned daemon to answer the socket. */
  startupTimeoutMs?: number;
}

export interface Daemon {
  start(opts: ServeOptions): Promise<number>;
  stop(): Promise<number>;
  restart(opts: ServeOptions): Promise<number>;
  status(): Promise<number>;
  logs(opts: { lines?: number; follow?: boolean }): Promise<number>;
}

const DEFAULT_LOG_LINES = 200;
const DEFAULT_STARTUP_TIMEOUT_MS = 3000;
const STARTUP_POLL_INTERVAL_MS = 50;

/** Build the argv for a detached `serve`, forwarding the user's serve flags. */
export function buildServeArgv(entry: string, opts: ServeOptions): string[] {
  const argv = [entry, "serve", "--host", opts.host, "--port", String(opts.port)];
  if (opts.advertise) argv.push("--advertise", opts.advertise);
  if (opts.noAuth) argv.push("--no-auth");
  for (const p of opts.projects) argv.push("--project", p);
  return argv;
}

/** Read a PID from the PID file, or `null` if missing/corrupt. */
export function readPidFile(path: string): number | null {
  try {
    const pid = Number.parseInt(readFileSync(path, "utf8").trim(), 10);
    return Number.isInteger(pid) && pid > 0 ? pid : null;
  } catch {
    return null;
  }
}

/** Write a PID to the PID file (creating the parent dir if needed). */
export function writePidFile(path: string, pid: number): void {
  mkdirSync(dirname(path), { recursive: true, mode: MAKIT_HOME_MODE });
  writeFileSync(path, `${pid}\n`, { mode: MAKIT_FILE_MODE });
  try {
    chmodSync(path, MAKIT_FILE_MODE);
  } catch {
    /* best-effort: perms may fail on exotic filesystems */
  }
}

export function createDaemon(deps: DaemonDeps): Daemon {
  const sleep = deps.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  const startupTimeoutMs = deps.startupTimeoutMs ?? DEFAULT_STARTUP_TIMEOUT_MS;

  function runningPid(): number | null {
    const pid = readPidFile(deps.pidPath);
    if (pid === null) return null;
    return deps.isAlive(pid) ? pid : null;
  }

  /** Poll the control socket until the freshly-spawned daemon answers. */
  async function waitForUp(): Promise<StatusData | null> {
    const attempts = Math.max(1, Math.ceil(startupTimeoutMs / STARTUP_POLL_INTERVAL_MS));
    for (let i = 0; i < attempts; i++) {
      const s = await fetchStatus();
      if (s) return s;
      if (i < attempts - 1) await sleep(STARTUP_POLL_INTERVAL_MS);
    }
    return null;
  }

  async function fetchStatus(): Promise<StatusData | null> {
    let client: ControlClient;
    try {
      client = await deps.connect(deps.socketPath);
    } catch {
      return null;
    }
    try {
      const res = await client.request<StatusData>("status");
      return res.ok && res.data ? res.data : null;
    } catch {
      return null;
    } finally {
      client.close();
    }
  }

  function printStatus(s: StatusData): void {
    deps.out(`makit: running`);
    deps.out(`  pid          ${s.pid}`);
    deps.out(`  listening    ${s.host}:${s.port}`);
    deps.out(`  fingerprint  ${s.fingerprint}`);
    deps.out(`  paired       ${s.pairedDevices} device(s)`);
    deps.out(`  sessions     ${s.runningSessions} running`);
    deps.out(`  uptime       ${Math.round(s.uptimeMs / 1000)}s`);
    deps.out(`  version      ${s.version}`);
  }

  return {
    async start(opts) {
      if (runningPid() !== null) {
        deps.out("makit: already running");
        const s = await fetchStatus();
        if (s) printStatus(s);
        return 0;
      }
      const logFd = deps.openLogFd(deps.logPath);
      const argv = buildServeArgv(deps.entry, opts);
      const child = deps.spawn(deps.execPath, argv, logFd);
      if (child.pid) writePidFile(deps.pidPath, child.pid);
      child.unref();
      // Don't report success until the child actually bound the control socket
      // — a serve that dies immediately (e.g. port in use) otherwise leaves a
      // "started" message and a PID file pointing at a dead process.
      const up = await waitForUp();
      if (!up) {
        rmSync(deps.pidPath, { force: true });
        deps.out(
          `makit: failed to start — no response within ${startupTimeoutMs}ms (see ${deps.logPath})`,
        );
        return 1;
      }
      deps.out(`makit: started (pid ${child.pid ?? up.pid}), logging to ${deps.logPath}`);
      return 0;
    },

    async stop() {
      const pid = runningPid();
      if (pid === null) {
        deps.out("makit: not running");
        rmSync(deps.pidPath, { force: true });
        return 0;
      }
      // PID-reuse guard: only SIGTERM when the control socket confirms a makit
      // daemon whose pid matches the PID file. After a crash the OS may recycle
      // the pid onto an unrelated process.
      const s = await fetchStatus();
      if (!s || s.pid !== pid) {
        deps.out("makit: not running (stale pid file)");
        rmSync(deps.pidPath, { force: true });
        return 0;
      }
      deps.kill(pid, "SIGTERM");
      rmSync(deps.pidPath, { force: true });
      deps.out(`makit: stopped (pid ${pid})`);
      return 0;
    },

    async restart(opts) {
      await this.stop();
      return this.start(opts);
    },

    async status() {
      const s = await fetchStatus();
      if (!s) {
        deps.out("makit: not running");
        return 3;
      }
      printStatus(s);
      return 0;
    },

    async logs(opts) {
      const lines = opts.lines ?? DEFAULT_LOG_LINES;
      let size = 0;
      if (existsSync(deps.logPath)) {
        const text = readFileSync(deps.logPath, "utf8");
        size = Buffer.byteLength(text);
        const all = text.split("\n");
        if (all.length > 0 && all[all.length - 1] === "") all.pop();
        for (const line of all.slice(-lines)) deps.out(line);
      }
      if (!opts.follow) return 0;
      // Follow: emit bytes appended after the initial read until interrupted.
      await followLog(deps.logPath, size, deps.out);
      return 0;
    },
  };
}

/**
 * Tail-follow a log file: on every change, read the bytes appended since the
 * last offset and emit each complete line. Runs until the process is
 * interrupted (Ctrl-C) — intended for the interactive `makit logs -f`.
 */
function followLog(path: string, from: number, out: (line: string) => void): Promise<void> {
  return new Promise(() => {
    let offset = from;
    let carry = "";
    const emitAppended = () => {
      if (!existsSync(path)) return;
      const text = readFileSync(path, "utf8");
      const bytes = Buffer.byteLength(text);
      if (bytes <= offset) return;
      carry += Buffer.from(text).subarray(offset).toString("utf8");
      offset = bytes;
      const parts = carry.split("\n");
      carry = parts.pop() ?? "";
      for (const line of parts) out(line);
    };
    watch(path, { persistent: true }, emitAppended);
  });
}
