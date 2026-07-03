/**
 * AuthGate — owns the `hello` handshake and the auth decision.
 *
 * Auth model (unchanged from the original god-function):
 *   - hello.bearer → long-lived paired-device token; matches a known device.
 *   - hello.pair   → short-lived QR pair token; on success mints a device and
 *     returns its bearer in `hello.ack.bearer`.
 *   - already-trusted (localhost dev, set by the caller) → ack without a token.
 *   - anything else → `err` + close 4401 (unauthorized).
 *
 * On successful auth the gate sends `hello.ack` and then invokes
 * `onAuthenticated(client)` so the caller can push initial snapshots — keeping
 * the ack-then-snapshot ordering identical to the pre-refactor behaviour.
 */

import type { Envelope } from "../protocol.js";
import { WireErrorCode } from "../protocol/codec.js";
import { log } from "../log.js";
import type { WsClient } from "./client.js";

/** The slice of the device registry the gate depends on. */
export interface AuthRegistry {
  authenticate(bearer: string): { id: string; label: string } | null;
  consumePairToken(
    token: string,
    label: string,
  ): { id: string; label: string; bearer: string } | null;
}

export interface AuthGateDeps {
  registry: AuthRegistry;
  /** Called after a successful `hello.ack`, to push initial snapshots. */
  onAuthenticated: (client: WsClient) => void;
  /** Shared secret that authenticates a `pino-mirror` extension host (host.json). */
  hostToken?: string;
}

const UNAUTHORIZED_CODE = 4401;

export class AuthGate {
  constructor(private readonly deps: AuthGateDeps) {}

  handleHello(client: WsClient, env: Envelope): void {
    const bearer = typeof env.bearer === "string" ? env.bearer : "";
    const pair = typeof env.pair === "string" ? env.pair : "";
    const label = typeof env.label === "string" ? env.label : "device";

    const host = typeof env.host === "string" ? env.host : "";
    if (host && this.deps.hostToken && host === this.deps.hostToken) {
      client.authed = true;
      client.deviceLabel = "host";
      client.send({ t: "hello.ack", id: env.id, ok: true });
      this.deps.onAuthenticated(client);
      return;
    }

    if (bearer) {
      this.handleBearer(client, env, bearer);
      return;
    }

    if (pair) {
      this.handlePair(client, env, pair, label);
      return;
    }

    if (client.authed) {
      // Already trusted (localhost dev mode).
      client.send({ t: "hello.ack", id: env.id, ok: true });
      this.deps.onAuthenticated(client);
      return;
    }

    this.reject(client, env, "missing bearer or pair token");
  }

  private handleBearer(client: WsClient, env: Envelope, bearer: string): void {
    const device = this.deps.registry.authenticate(bearer);
    if (!device) {
      log.warn("[pino] hello: unknown bearer (rejected)");
      this.reject(client, env, "unknown device");
      return;
    }
    client.authed = true;
    client.deviceLabel = device.label;
    client.send({ t: "hello.ack", id: env.id, ok: true, deviceId: device.id });
    log.info(`[pino] hello: authed as ${device.label} (${device.id}); sent snapshots`);
    this.deps.onAuthenticated(client);
  }

  private handlePair(
    client: WsClient,
    env: Envelope,
    pair: string,
    label: string,
  ): void {
    const device = this.deps.registry.consumePairToken(pair, label);
    if (!device) {
      this.reject(client, env, "invalid or expired pairing token");
      return;
    }
    client.authed = true;
    client.deviceLabel = device.label;
    log.info(`[pino] paired new device: ${device.label} (${device.id})`);
    client.send({
      t: "hello.ack",
      id: env.id,
      ok: true,
      deviceId: device.id,
      bearer: device.bearer,
    });
    this.deps.onAuthenticated(client);
  }

  private reject(client: WsClient, env: Envelope, message: string): void {
    client.send({ t: "err", id: env.id, code: WireErrorCode.Unauthorized, message });
    client.close(UNAUTHORIZED_CODE, "unauthorized");
  }
}
