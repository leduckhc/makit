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
import type { SessionDTO } from "../protocol.js";

export interface OpenClientOpts {
  host: string;
  port: number;
  bearer: string;
  /** Verify the server cert. Defaults false: the CLI talks to loopback, self-signed. */
  rejectUnauthorized?: boolean;
}

export interface SessionsSnapshot {
  sessions: SessionDTO[];
  /** The raw frame as received, so `--json` can emit the wire unmodified (D7). */
  frame: Record<string, unknown>;
}

export interface MakitClient {
  /** Send `hello`; resolve on `hello.ack`, reject on `err`/close (never hang). */
  hello(): Promise<void>;
  /** Send a `cmd` and resolve the `ack` frame that matches its id; reject on `err`. */
  cmd(kind: string, fields?: Record<string, unknown>): Promise<Record<string, unknown>>;
  /** Resolve with the cached `sessions.snapshot`, or the next one pushed. */
  awaitSnapshot(): Promise<SessionsSnapshot>;
  /** Close the socket and reject anything in flight. Idempotent. */
  close(): void;
}

/** An auth failure (`hello` rejected). Callers map this to exit code 4 (C4/D8). */
export class AuthError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AuthError";
  }
}

type Pending = { resolve: (frame: Record<string, unknown>) => void; reject: (err: Error) => void };

/** Open a WSS client, resolving once the socket is open (rejecting on connect error). */
export function openClient(opts: OpenClientOpts): Promise<MakitClient> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`wss://${opts.host}:${opts.port}`, {
      rejectUnauthorized: opts.rejectUnauthorized ?? false,
    });

    const pending = new Map<string, Pending>();
    let helloPending: Pending | undefined;
    let snapshot: SessionsSnapshot | undefined;
    let snapshotWaiter: ((s: SessionsSnapshot) => void) | undefined;
    let closed = false;
    let seq = 0;

    const failAll = (err: Error) => {
      helloPending?.reject(err);
      helloPending = undefined;
      for (const p of pending.values()) p.reject(err);
      pending.clear();
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
          p.reject(new Error(message));
        }
        return;
      }
      if (m.t === "ack") {
        const p = pending.get(id);
        if (p) {
          pending.delete(id);
          p.resolve(m);
        }
        return;
      }
      if (m.t === "event" && m.kind === "sessions.snapshot") {
        snapshot = { sessions: (m.sessions as SessionDTO[]) ?? [], frame: m };
        snapshotWaiter?.(snapshot);
        snapshotWaiter = undefined;
        return;
      }
    });

    ws.on("open", () => {
      resolve({
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
            ws.send(JSON.stringify({ v: 1, t: "cmd", id, kind, ...fields }));
          });
        },
        awaitSnapshot() {
          if (snapshot) return Promise.resolve(snapshot);
          if (closed) return Promise.reject(new Error("client closed"));
          return new Promise((res) => {
            snapshotWaiter = res;
          });
        },
        close() {
          if (closed) return;
          closed = true;
          failAll(new Error("client closed"));
          ws.close();
          ws.terminate();
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
