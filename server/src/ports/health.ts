/**
 * health.ts — the deliberately narrow HTTP probe (spec D3).
 *
 * Only ports attributed to a worktree are probed, minus a database deny-list,
 * and only on the LOOPBACK form of the address. Pointing `GET /` at every
 * listener on the machine would poke X11, VNC, SMTP, LDAP and TLS-only services
 * and render a healthy HTTPS server as broken. One `GET / HTTP/1.1` +
 * `Connection: close`, read only far enough to parse the status line.
 *
 * Everything with a wall-clock or a socket is injected (`connect`, `now`,
 * `setTimer`, `clearTimer`) so tests never open a real socket. `refresh` NEVER
 * throws — a failed probe is a verdict, not an exception.
 */

import type { PortDTO, PortHealthDTO, PortHealthKind } from "../protocol.js";
import { mapLimit } from "../concurrency.js";
import { connect as netConnect } from "node:net";

/** Reading the status line must not hang a scan; 800 ms is generous for local. */
export const PROBE_TIMEOUT_MS = 800;
/** A verdict is reused for 10 s (stale-while-revalidate) before a re-probe. */
export const PROBE_TTL_MS = 10_000;
/** Cap simultaneous probes so a machine with many dev servers is not hammered. */
export const PROBE_CONCURRENCY = 12;
/** A 4xx boundary: 2xx/3xx answer, 4xx/5xx are an HTTP error. */
const HTTP_ERROR_STATUS = 400;

/**
 * Ports where an HTTP `GET /` is known log-noise or actively wrong: SSH and the
 * common databases (Postgres, MySQL, Redis, Mongo, Memcached). Being wrong about
 * one costs only a missing verdict, so this is a short courtesy list, not
 * protocol detection (spec D3).
 */
export const NO_HTTP_PROBE_PORTS: readonly number[] = [22, 5432, 3306, 6379, 27017, 11211];

/** The minimal socket surface the probe drives; the real one wraps `net.Socket`. */
export interface ProbeSocket {
  write(data: string): void;
  on(event: "data", cb: (chunk: string) => void): void;
  on(event: "error", cb: (err: NodeJS.ErrnoException) => void): void;
  on(event: "close", cb: () => void): void;
  destroy(): void;
}

/** Opens a TCP connection to a loopback endpoint. Injected; tests never spawn one. */
export type Connector = (host: string, port: number) => ProbeSocket;

export interface PortHealthProbeDeps {
  connect: Connector;
  now: () => number;
  setTimer: (fn: () => void, ms: number) => unknown;
  clearTimer: (handle: unknown) => void;
}

/**
 * The loopback form to talk to, or null when the address has none (a concrete
 * non-loopback bind, e.g. a tailnet IP): a wildcard covers loopback, `127.x`
 * and `::1` are already loopback, everything else is not probed.
 */
function loopbackForm(address: string): string | null {
  if (address === "*" || address === "0.0.0.0") return "127.0.0.1";
  if (address === "::") return "::1";
  if (address === "::1") return "::1";
  if (address.startsWith("127.")) return address;
  return null;
}

/** Parse the first response line into a verdict. Anything unparseable is http-error. */
function classifyStatusLine(line: string): { kind: PortHealthKind; status?: number } {
  const match = line.match(/^HTTP\/\d(?:\.\d)?\s+(\d{3})/);
  if (!match) return { kind: "http-error" }; // a response arrived, just not parseable
  const status = Number(match[1]);
  return { kind: status < HTTP_ERROR_STATUS ? "ok" : "http-error", status };
}

export class PortHealthProbe {
  private readonly deps: PortHealthProbeDeps;
  /** Latest verdict per `<address>:<port>` (the key attribution queries by). */
  private readonly cache = new Map<string, PortHealthDTO>();

  constructor(deps: PortHealthProbeDeps) {
    this.deps = deps;
  }

  /** The cached verdict for an endpoint (possibly stale), or undefined if never probed. */
  verdict(address: string, port: number): PortHealthDTO | undefined {
    return this.cache.get(`${address}:${port}`);
  }

  /**
   * Probe every eligible port whose cached verdict is stale, bounded by
   * {@link PROBE_CONCURRENCY}. Resolves once all probes settle; never rejects.
   */
  async refresh(ports: PortDTO[]): Promise<void> {
    const now = this.deps.now();
    const due = ports.filter((p) => {
      if (p.worktreePath === undefined) return false; // unowned → not probed (D3)
      if (NO_HTTP_PROBE_PORTS.includes(p.port)) return false; // deny-listed
      if (loopbackForm(p.address) === null) return false; // no loopback form
      const cached = this.cache.get(`${p.address}:${p.port}`);
      return cached === undefined || now - cached.probedAt >= PROBE_TTL_MS;
    });

    await mapLimit(due, PROBE_CONCURRENCY, async (p) => {
      const host = loopbackForm(p.address)!;
      const verdict = await this.probeOne(host, p.port);
      this.cache.set(`${p.address}:${p.port}`, verdict);
    });
  }

  /** One probe. Always resolves to a verdict — connect/socket faults are `refused`. */
  private probeOne(host: string, port: number): Promise<PortHealthDTO> {
    return new Promise<PortHealthDTO>((resolve) => {
      let settled = false;
      const finish = (kind: PortHealthKind, status?: number): void => {
        if (settled) return;
        settled = true;
        this.deps.clearTimer(timer);
        try {
          socket.destroy();
        } catch {
          // Tearing down a probe socket must never surface (spec: refresh never throws).
        }
        const verdict: PortHealthDTO = { kind, probedAt: this.deps.now() };
        if (status !== undefined) verdict.status = status;
        resolve(verdict);
      };

      // Arm the timeout BEFORE connecting: a connector that throws synchronously
      // still needs the timer reference to exist for finish().
      const timer = this.deps.setTimer(() => finish("timeout"), PROBE_TIMEOUT_MS);

      let socket: ProbeSocket;
      try {
        socket = this.deps.connect(host, port);
      } catch {
        finish("refused");
        return;
      }

      let buffer = "";
      socket.on("data", (chunk) => {
        buffer += chunk;
        const nl = buffer.indexOf("\n");
        if (nl < 0) return; // status line not complete yet
        const { kind, status } = classifyStatusLine(buffer.slice(0, nl).trimEnd());
        finish(kind, status);
      });
      // Any connect/socket error, or a close before a status line, is "refused":
      // the port is listening (lsof said so) but nothing answered HTTP.
      socket.on("error", () => finish("refused"));
      socket.on("close", () => finish("refused"));

      socket.write(`GET / HTTP/1.1\r\nHost: ${host}\r\nConnection: close\r\n\r\n`);
    });
  }
}

/**
 * The production connector: a real loopback TCP socket. Kept out of the class so
 * `node:net` never enters a test's path (every test injects a fake connector).
 * `setEncoding("utf8")` makes `data` deliver strings, which is all the probe reads.
 */
export function createNetConnector(): Connector {
  return (host, port) => {
    const socket = netConnect({ host, port });
    socket.setEncoding("utf8");
    return {
      write: (data) => void socket.write(data),
      on: (event, cb) => void socket.on(event, cb as (...args: unknown[]) => void),
      destroy: () => void socket.destroy(),
    };
  };
}
