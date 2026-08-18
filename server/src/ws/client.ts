/**
 * Shared view of a connected WebSocket client, as seen by the WS-server
 * collaborators (auth gate, command router, subscription hub, reverse RPC).
 *
 * The concrete implementation in `server.ts` wraps a live `ws` socket; tests
 * substitute a lightweight fake that records frames. Structural typing means
 * neither needs to import the other.
 */

import type { Envelope } from "../protocol.js";
import type { Principal } from "./principal.js";

/** A frame ready to send, minus the protocol version the transport stamps. */
export type OutgoingFrame = Omit<Envelope, "v">;

export interface WsClient {
  /** Serialize + send a frame (no-op if the socket is not open). */
  send(frame: OutgoingFrame): void;
  /** Close the underlying socket with a status code + reason. */
  close(code: number, reason: string): void;
  /** Session ids this client is subscribed to. */
  readonly subscribed: Set<string>;
  /** True once the client has completed the `hello` handshake. */
  authed: boolean;
  /** Human label of the paired device, once known. */
  deviceLabel?: string;
  /** Registry id of the paired device, once authenticated (for `devices.list`). */
  deviceId?: string;
  /**
   * The authenticated subject (SPEC-cli-as-client D17), set by `AuthGate` on a successful
   * `hello`. **Undefined on an unauthed socket, and undefined means full access
   * once authed** — every device paired before SPEC-cli-as-client has no capabilities, so
   * the absence of a principal must never be read as "deny".
   *
   * Read by the command router (capability check) and by fanout (a
   * session-scoped principal sees only its own session's events).
   */
  principal?: Principal;
  /**
   * True while this client is watching metrics (`metrics.watch {on:true}`).
   * Cleared on socket close so a panel closed by killing the window cannot pin
   * the collector at 1 Hz forever (SPEC-performance-metrics-dashboard decision 7).
   */
  watchingMetrics: boolean;
  /**
   * True while this client is watching ports (`ports.watch {on:true}`, SPEC-open-ports).
   * Required (like {@link watchingMetrics}): every `WsClient` initialises it to
   * `false`. Cleared on socket close so a killed window cannot pin the `lsof`
   * scanner running forever.
   */
  watchingPorts: boolean;
  /**
   * True while this client is watching docs (`docs.watch {on:true}`, SPEC-doc-preview).
   * Required (like {@link watchingPorts}): every `WsClient` initialises it to
   * `false`. Cleared on socket close so a killed window cannot keep the doc
   * index re-walking on every tree change forever.
   */
  watchingDocs: boolean;
  /**
   * True when the socket's remote address is loopback. Gates acceptance of the
   * app's reported pid in `hello` (SPEC-performance-metrics-dashboard decision 6) — a non-loopback client
   * must connect normally but may not ask us to sample an arbitrary pid.
   */
  readonly isLocal: boolean;
  /**
   * The app process pid this (loopback) client reported in `hello`, used to
   * measure the app's CPU/RSS from the server. Undefined until reported and for
   * every non-loopback client.
   */
  appPid?: number;
}
