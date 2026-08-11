/**
 * The shared WSS client for `makit`'s session verbs (SPEC-46, T6/D1).
 *
 * The CLI is a first-class client — a peer of the phone on the SAME WSS
 * protocol, same `hello` auth, same DTOs — so it cannot drift from the app by
 * construction (D1). This module is the transport every session verb (`ls`,
 * `attach`, and the P1 verbs) is a thin client of:
 *
 *   - connect + `hello` (rejects on an auth failure instead of hanging),
 *   - `cmd`/`ack` correlation by frame id,
 *   - a cache of the `sessions.snapshot` the server pushes on auth,
 *   - a clean teardown that rejects in-flight work and leaves no open handle.
 *
 * Credential resolution (D2/D3) — this is the whole point of the CLI having an
 * identity of its own, replacing `attach.ts`'s deleted `devices.json[0]` hack:
 *   1. `MAKIT_CLI_TOKEN` — a per-session token in an agent's environment, so an
 *      agent inside a makit session can drive makit with no arguments;
 *   2. `~/.makit/cli.json` — the cached `cli@<host>` device credential (0600);
 *   3. `cli.grant` over the control socket — minted on first use, then cached.
 */
import { WebSocket } from "ws";
import { join } from "node:path";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { makitHome } from "../daemon/paths.js";
import type { CliGrantData, ControlResponse, ControlVerb } from "../daemon/protocol.js";
import type { ProjectDTO, SessionDTO } from "../protocol.js";

export interface OpenClientOpts {
  host: string;
  port: number;
  bearer: string;
  /**
   * Verify the server cert. Defaults to {@link verifiesCert}: **off for
   * loopback** (where the cert is self-signed and the peer is this machine),
   * **on for anything else**.
   */
  rejectUnauthorized?: boolean;
}

/**
 * Whether the cert must be verified for `host`.
 *
 * The blanket `rejectUnauthorized: false` was justified by "the CLI talks to
 * loopback, self-signed" — true of the default target, but `host` comes from
 * `--host` argv, so the exemption silently covered every remote host as well.
 * D11 makes remote a P3 feature that **pins the fingerprint the app pins**;
 * until that exists, a remote target must fail loudly rather than connect with
 * verification quietly disabled.
 */
export function verifiesCert(host: string, explicit?: boolean): boolean {
  if (explicit !== undefined) return explicit;
  return !isLoopback(host);
}

function isLoopback(host: string): boolean {
  const h = host.replace(/^\[|\]$/g, "").toLowerCase();
  if (h === "localhost" || h.endsWith(".localhost")) return true;
  if (h === "::1" || h === "0:0:0:0:0:0:0:1") return true;
  return /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(h);
}

export interface SessionsSnapshot {
  sessions: SessionDTO[];
  /** The raw frame as received, so `--json` can emit the wire unmodified (D7). */
  frame: Record<string, unknown>;
}

export interface MakitClient {
  /**
   * The credential this connection authenticated with. Exposed because `POST
   * /media` (SPEC-33) rides the same listener with the same bearer, so a verb
   * that attaches a file must not resolve a second one.
   */
  readonly bearer: string;
  /** Send `hello`; resolve on `hello.ack`, reject on `err`/close (never hang). */
  hello(): Promise<void>;
  /** Send a `cmd` and resolve the `ack` frame that matches its id; reject on `err`. */
  cmd(kind: string, fields?: Record<string, unknown>): Promise<Record<string, unknown>>;
  /**
   * Resolve with the cached `sessions.snapshot`, or the next one pushed — and
   * reject if none arrives within {@link SNAPSHOT_TIMEOUT_MS}. Bounded because a
   * verb that never reaches an exit code is the one outcome D8's contract cannot
   * express: rejecting on close is not enough, since a server that stays up and
   * simply never pushes would wait forever.
   */
  awaitSnapshot(): Promise<SessionsSnapshot>;
  /** As {@link awaitSnapshot}, for `projects.snapshot`, and bounded the same way. */
  awaitProjects(): Promise<ProjectDTO[]>;
  /** Send a raw frame (`sub`, `srv.response`, …) with no reply correlation. The
   * optional `onSent` fires once the frame is written to the socket, so a
   * caller that closes immediately after (e.g. `approve`/`answer`) does not
   * terminate the connection before the frame flushes. */
  send(frame: Record<string, unknown>, onSent?: () => void): void;
  /**
   * Every frame this client did not answer itself: events, `srv.request`, and
   * acks nobody is awaiting. The streaming verbs (`attach`, `tail`) live here.
   */
  onFrame(cb: (frame: Record<string, unknown>) => void): void;
  /** Called once when the socket closes, however it closed. */
  onClose(cb: () => void): void;
  /** Close the socket and reject anything in flight. Idempotent. */
  close(): void;
}

/**
 * A command the server refused (an `err` frame answering a `cmd`) — a spawn past
 * the depth bound, an unknown session, a capability the principal lacks. Distinct
 * from a thrown Error so a verb can report the refusal as a sentence and leave
 * genuine bugs to surface with their stack.
 */
/**
 * An **expected refusal**: the server understood the request and declined it, or
 * the operation failed for a reason the user needs to read rather than debug.
 *
 * This is the CLI's one non-credential failure class, and it is deliberately not
 * tied to the WebSocket: `POST /media` rides a different transport but fails the
 * same way, so it raises this too. Callers do not handle it individually —
 * {@link withClient} maps it to a sentence and exit 1, which is what keeps a
 * refusal from reaching an agent's shell as a stack trace.
 */
export class WireError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "WireError";
  }
}

/** An auth failure (`hello` rejected). Callers map this to exit code 4 (C4/D8). */
export class AuthError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AuthError";
  }
}

type Pending = { resolve: (frame: Record<string, unknown>) => void; reject: (err: Error) => void };
type Waiter<T> = { resolve: (value: T) => void; reject: (err: Error) => void };

/**
 * How long a verb waits for a snapshot the server pushes unprompted, before it
 * gives up and says so.
 *
 * The server sends both snapshots immediately after `hello.ack`, so this only
 * ever fires when something is genuinely wrong. It exists because the failure it
 * replaces has no upper bound: an unpushed snapshot left the socket open and the
 * event loop alive, so the verb produced no output and no exit code — which in
 * CI is a job cancelled minutes later with nothing naming the cause.
 */
export const SNAPSHOT_TIMEOUT_MS = 15_000;

/** Reject `waiters` if nothing has settled them within `SNAPSHOT_TIMEOUT_MS`. */
function armWaiterTimeout<T>(waiters: Waiter<T>[], what: string): void {
  const waiter = waiters[waiters.length - 1]!;
  const timer = setTimeout(() => {
    const i = waiters.indexOf(waiter);
    if (i === -1) return; // already settled
    waiters.splice(i, 1);
    waiter.reject(new Error(`timed out after ${SNAPSHOT_TIMEOUT_MS}ms waiting for ${what}`));
  }, SNAPSHOT_TIMEOUT_MS);
  // Unref'd: the timer must never be the reason the process stays alive.
  timer.unref();
}

/** Open a WSS client, resolving once the socket is open (rejecting on connect error). */
export function openClient(opts: OpenClientOpts): Promise<MakitClient> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`wss://${opts.host}:${opts.port}`, {
      rejectUnauthorized: verifiesCert(opts.host, opts.rejectUnauthorized),
    });

    const pending = new Map<string, Pending>();
    let helloPending: Pending | undefined;
    let snapshot: SessionsSnapshot | undefined;
    let projects: ProjectDTO[] | undefined;
    /**
     * Snapshot/projects awaits are the only ones not keyed by a frame id, so
     * they are the two `failAll` can silently skip — and an unsettled promise
     * here holds an open handle, so the verb never reaches an exit code at all
     * (D8). They are **lists** because a single slot would let a second caller
     * overwrite the first's resolver and orphan it permanently.
     */
    const snapshotWaiters: Waiter<SessionsSnapshot>[] = [];
    const projectsWaiters: Waiter<ProjectDTO[]>[] = [];
    let frameCb: ((frame: Record<string, unknown>) => void) | undefined;
    /**
     * Frames that arrived before a caller registered `onFrame`. `hello` is sent
     * inside the connect step and the server pushes its snapshots immediately
     * after `hello.ack`, so without this buffer a streaming caller would miss
     * the very frames it connected for.
     */
    const early: Record<string, unknown>[] = [];
    const emit = (m: Record<string, unknown>) => {
      if (frameCb) frameCb(m);
      else early.push(m);
    };
    let closeCb: (() => void) | undefined;
    let closed = false;
    let seq = 0;

    const failAll = (err: Error) => {
      helloPending?.reject(err);
      helloPending = undefined;
      for (const p of pending.values()) p.reject(err);
      pending.clear();
      for (const w of snapshotWaiters.splice(0)) w.reject(err);
      for (const w of projectsWaiters.splice(0)) w.reject(err);
    };

    ws.on("message", (buf: Buffer) => {
      let m: Record<string, unknown>;
      try {
        m = JSON.parse(buf.toString());
      } catch {
        return;
      }
      const id = typeof m.id === "string" ? m.id : "";
      if (m.t === "hello.ack") {
        helloPending?.resolve(m);
        helloPending = undefined;
        return;
      }
      if (m.t === "err") {
        const message = typeof m.message === "string" ? m.message : "request failed";
        if (helloPending) {
          helloPending.reject(new AuthError(message));
          helloPending = undefined;
          return;
        }
        const p = pending.get(id);
        if (p) {
          pending.delete(id);
          p.reject(new WireError(message));
          return;
        }
        emit(m);
        return;
      }
      if (m.t === "ack") {
        const p = pending.get(id);
        if (p) {
          pending.delete(id);
          p.resolve(m);
          return;
        }
        emit(m);
        return;
      }
      if (m.t === "event" && m.kind === "projects.snapshot") {
        projects = (m.projects as ProjectDTO[]) ?? [];
        for (const w of projectsWaiters.splice(0)) w.resolve(projects);
      }
      if (m.t === "event" && m.kind === "sessions.snapshot") {
        snapshot = { sessions: (m.sessions as SessionDTO[]) ?? [], frame: m };
        for (const w of snapshotWaiters.splice(0)) w.resolve(snapshot);
      }
      emit(m);
    });

    ws.on("open", () => {
      resolve({
        bearer: opts.bearer,
        hello() {
          return new Promise<void>((res, rej) => {
            if (closed) return rej(new Error("client closed"));
            helloPending = { resolve: () => res(), reject: rej };
            ws.send(JSON.stringify({ v: 1, t: "hello", id: "h", bearer: opts.bearer }));
          });
        },
        cmd(kind, fields = {}) {
          return new Promise((res, rej) => {
            if (closed) return rej(new Error("client closed"));
            const id = `c${++seq}`;
            pending.set(id, { resolve: res, reject: rej });
            // `fields` is spread FIRST so the protocol envelope always wins. Several
            // verbs forward user-derived values (`text` from argv, a manifest an LLM
            // wrote), and a key collision must not be able to rewrite `id` — which
            // is how this reply is correlated — or `t`/`kind`, which is how it routes.
            ws.send(JSON.stringify({ ...fields, v: 1, t: "cmd", id, kind }));
          });
        },
        awaitSnapshot() {
          if (snapshot) return Promise.resolve(snapshot);
          if (closed) return Promise.reject(new Error("client closed"));
          return new Promise((resolve, reject) => {
            snapshotWaiters.push({ resolve, reject });
            armWaiterTimeout(snapshotWaiters, "sessions.snapshot");
          });
        },
        awaitProjects() {
          if (projects) return Promise.resolve(projects);
          if (closed) return Promise.reject(new Error("client closed"));
          return new Promise((resolve, reject) => {
            projectsWaiters.push({ resolve, reject });
            armWaiterTimeout(projectsWaiters, "projects.snapshot");
          });
        },
        send(frame, onSent) {
          if (!closed && ws.readyState === WebSocket.OPEN) {
            // `v` last for the same reason `cmd` puts the envelope last: a frame
            // body may carry caller-supplied keys.
            ws.send(JSON.stringify({ ...frame, v: 1 }), () => onSent?.());
          } else {
            onSent?.();
          }
        },
        onFrame(cb) {
          frameCb = cb;
          for (const m of early.splice(0)) cb(m);
        },
        onClose(cb) {
          closeCb = cb;
        },
        close() {
          if (closed) return;
          closed = true;
          failAll(new Error("client closed"));
          // Graceful close flushes any just-sent frame (e.g. an `srv.response`)
          // before the socket goes away; a terminate() fallback — unref'd so it
          // never keeps the process alive — guarantees teardown if the close
          // handshake stalls.
          ws.close();
          setTimeout(() => ws.terminate(), 1000).unref();
        },
      });
    });

    ws.on("error", (err: Error) => {
      reject(err); // no-op once open has resolved
      failAll(err);
    });

    ws.on("close", () => {
      closed = true;
      failAll(new Error("connection closed"));
      closeCb?.();
    });
  });
}

// --------------------------------------------------------------------------
// Credential resolution (D2/D3)
// --------------------------------------------------------------------------

/** Where the `cli@<host>` device credential is cached (D2). */
export function cliCredentialPath(): string {
  return join(makitHome(), "cli.json");
}

/** The minimal control-socket surface `resolveBearer` needs (for testability). */
export interface CliGrantControl {
  request(verb: ControlVerb, args?: Record<string, unknown>): Promise<ControlResponse>;
}

/**
 * Resolve the bearer this CLI process should authenticate with, in the order
 * D2/D3 mandate: the agent-scoped env token, then the cached device credential,
 * then a freshly minted `cli.grant` (which we cache at mode 0600).
 */
export async function resolveBearer(control: CliGrantControl): Promise<string> {
  const envToken = process.env.MAKIT_CLI_TOKEN;
  if (envToken) return envToken;

  const cachedPath = cliCredentialPath();
  try {
    const cached = JSON.parse(readFileSync(cachedPath, "utf8")) as { bearer?: string };
    if (cached.bearer) return cached.bearer;
  } catch {
    // No cache yet (or unreadable) — fall through to minting.
  }

  const res = await control.request("cli.grant");
  const granted = res.ok ? (res.data as CliGrantData | undefined) : undefined;
  if (!granted?.bearer) {
    throw new AuthError(`cli.grant failed: ${res.ok ? "no bearer returned" : res.error}`);
  }
  const { deviceId, label, bearer } = granted;
  mkdirSync(makitHome(), { recursive: true });
  writeFileSync(cachedPath, JSON.stringify({ deviceId, label, bearer }), { mode: 0o600 });
  return bearer;
}
