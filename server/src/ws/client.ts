/**
 * Shared view of a connected WebSocket client, as seen by the WS-server
 * collaborators (auth gate, command router, subscription hub, reverse RPC).
 *
 * The concrete implementation in `server.ts` wraps a live `ws` socket; tests
 * substitute a lightweight fake that records frames. Structural typing means
 * neither needs to import the other.
 */

import type { Envelope } from "../protocol.js";

/** A frame ready to send, minus the protocol version the transport stamps. */
export type OutgoingFrame = Omit<Envelope, "v">;

export interface WsClient {
  /** Serialize + send a frame (no-op if the socket is not open). */
  send(frame: OutgoingFrame): void;
  /** Close the underlying socket with a status code + reason. */
  close(code: number, reason: string): void;
  /** Session ids this client is subscribed to. */
  readonly subscribed: Set<string>;
  /** Multiplexer pane targets this client is mirroring (POC pane bridge). */
  panes?: Set<string>;
  /** True once the client has completed the `hello` handshake. */
  authed: boolean;
  /** Human label of the paired device, once known. */
  deviceLabel?: string;
}
