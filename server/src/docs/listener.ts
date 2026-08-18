/**
 * makit — SPEC-doc-preview D10 rev 2: the doc listener, bound only while it is in use.
 *
 * rev 1 bound a routable port at startup and kept it open for the whole life of
 * the server, whether or not anything was ever published. That is an always-on
 * network surface for a feature you may never touch, so this binds **lazily on
 * the first publish** and releases the port as soon as the last grant is gone.
 *
 * rev 2 also drops the LAN fallback that rev 1's D15 called for. The capability
 * lives in the URL path (D9), and on a LAN that URL would cross the wire in
 * cleartext; on the tailnet WireGuard already encrypts it. So there is exactly
 * one publishable reach — `tailnet` — and no Tailscale means publish is
 * unavailable with a stated reason, which is still degrading loudly.
 *
 * Plain HTTP is deliberate and sufficient here: the transport is encrypted by
 * the tailnet, and the URL is never typed by a human (it is tapped, copied, or
 * scanned from a QR), so a `ts.net` hostname would buy nothing that justifies a
 * `tailscale serve` lifecycle.
 */

import { createServer as defaultCreateServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";

import { log } from "../log.js";
import type { DocReach } from "./publish.js";

export interface DocListenerDeps {
  /**
   * The routable tailnet address to bind, or `null` when makit is loopback-only
   * or wildcard-bound — in which case nothing is ever bound and publish refuses.
   */
  bindHost: string | null;
  /** Injected for tests. */
  createServer?: () => Server;
  /** Install the doc route (and its terminating 404) on a freshly-made server. */
  attach: (server: Server) => void;
  /** Fixed port, for tests that need a predictable bind failure. 0 = ephemeral. */
  port?: number;
}

export class DocListener {
  private server: Server | undefined;
  private origin: DocReach | undefined;
  /**
   * The bind in flight, so concurrent publishes share one attempt. Without it
   * two simultaneous `publish` calls both pass the `origin === undefined` check
   * and bind two ports, and the first listener is leaked with no way to close it.
   */
  private binding: Promise<DocReach | null> | undefined;
  /**
   * The close in flight, so a publish arriving mid-close waits for the socket to
   * come fully down before binding a fresh one. Without it, `ensureOrigin` sees
   * `origin` already cleared and binds a second port while the first is still
   * shutting down — two live listeners, the opposite of what `close` promises.
   */
  private closing: Promise<void> | undefined;
  private readonly deps: DocListenerDeps;

  constructor(deps: DocListenerDeps) {
    this.deps = deps;
  }

  /** True while a port is actually bound. */
  get isListening(): boolean {
    return this.server !== undefined;
  }

  /**
   * The verified origin fronting the doc route, binding one if needed. `null`
   * when there is no tailnet address or the bind failed — publish must then
   * share nothing and say why (D15). Never returns an unbound origin.
   */
  async ensureOrigin(): Promise<DocReach | null> {
    if (this.origin !== undefined) return this.origin;
    // Join an in-flight bind rather than starting a second one.
    if (this.binding !== undefined) return this.binding;
    // Serialise against an in-flight close: bind only once the old socket is
    // fully down, so the two can never both be live.
    if (this.closing !== undefined) await this.closing;

    const host = this.deps.bindHost;
    if (host === null) return null;

    this.binding = this.bindOnce(host).finally(() => {
      this.binding = undefined;
    });
    return this.binding;
  }

  private async bindOnce(host: string): Promise<DocReach | null> {
    const server = (this.deps.createServer ?? defaultCreateServer)();
    this.deps.attach(server);

    const port = await bind(server, this.deps.port ?? 0, host);
    if (port === null) {
      server.close();
      return null;
    }

    this.server = server;
    this.origin = { origin: `http://${host}:${port}`, reach: "tailnet" };
    log.info(`[makit] docs listening on ${this.origin.origin} (published docs only)`);
    return this.origin;
  }

  /**
   * Release the port when `liveGrants` is zero. Called after a revoke, and after
   * any read of the grant list (which reaps expired grants on the way through),
   * so an expiry frees the port without needing a timer of its own.
   */
  async releaseIfIdle(liveGrants: number): Promise<void> {
    if (liveGrants > 0) return;
    await this.close();
  }

  /**
   * Close the listener if bound. Idempotent.
   *
   * The fields are cleared before `close()` resolves, so a publish arriving mid
   * close would bind a fresh listener on a new port while the old socket is
   * still shutting down. Awaiting the closure first keeps the two serialised:
   * one listener at a time, always.
   */
  async close(): Promise<void> {
    // A close already in flight: join it rather than starting a second teardown.
    if (this.closing !== undefined) return this.closing;
    this.closing = this.doClose().finally(() => {
      this.closing = undefined;
    });
    return this.closing;
  }

  private async doClose(): Promise<void> {
    const binding = this.binding;
    if (binding !== undefined) await binding.catch(() => null);

    const server = this.server;
    this.server = undefined;
    this.origin = undefined;
    if (server === undefined) return;
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

/** Listen, resolving the bound port, or `null` when the bind failed. */
function bind(server: Server, port: number, host: string): Promise<number | null> {
  return new Promise((resolve) => {
    const onError = (err: NodeJS.ErrnoException): void => {
      log.warn(`[makit] doc listener could not bind ${host}:${port}: ${err.message}`);
      server.removeListener("listening", onListening);
      resolve(null);
    };
    const onListening = (): void => {
      server.removeListener("error", onError);
      // Keep a persistent 'error' handler for the life of the socket. An
      // unhandled 'error' on an http.Server (e.g. EMFILE/ENFILE under load on a
      // routable, unauthenticated listener) crashes the whole process, so it
      // must be logged and swallowed rather than left to propagate.
      server.on("error", (err: NodeJS.ErrnoException) => {
        log.warn(`[makit] doc listener error on ${host}:${port}: ${err.message}`);
      });
      resolve((server.address() as AddressInfo).port);
    };
    server.once("error", onError);
    server.once("listening", onListening);
    server.listen(port, host);
  });
}
