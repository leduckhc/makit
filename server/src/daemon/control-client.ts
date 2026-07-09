/**
 * Control client (SPEC-01, phase 3).
 *
 * A tiny reusable client for the makit control socket. **Exported for SPEC-02**:
 * the CLI subcommands (`makit qr`, `makit devices`, …) connect once and issue
 * requests against a running daemon.
 *
 * Usage:
 *   const client = await connectControlClient(controlSocketPath());
 *   const res = await client.request("status");
 *   client.close();
 *
 * ## Contract note for non-Node clients (SPEC-03 desktop app / Dart)
 *
 * The protocol is transport-agnostic NDJSON, not tied to this class. To talk to
 * the daemon from any language: open the unix socket, write
 * `JSON.stringify({ id, verb, args? }) + "\n"`, and read newline-delimited
 * responses `{ id, ok, data|error }`, correlating by `id`. The single-response
 * verbs resolve on the first matching frame; `logs.tail --follow` streams
 * `{ id, ok, data:{ line } }` frames until the socket closes.
 */

import { connect, type Socket } from "node:net";
import {
  encodeMessage,
  decodeResponse,
  LineBuffer,
  type ControlVerb,
  type ControlResponse,
} from "./protocol.js";

export interface ControlClient {
  /**
   * Issue a request and resolve the FIRST response frame that matches its id.
   *
   * Note: because it resolves on the first matching frame, this method cannot
   * consume the multi-frame `logs.tail --follow` stream (which emits many
   * `{ id, ok, data:{ line } }` frames for one request id). The CLI `makit logs
   * -f` therefore reads the log file directly rather than through this client.
   * A streaming client API is deferred to SPEC-02, when a real consumer needs
   * it (YAGNI — no consumer exists yet).
   */
  request<T = unknown>(
    verb: ControlVerb,
    args?: Record<string, unknown>,
  ): Promise<ControlResponse<T>>;
  /** Close the socket, rejecting any in-flight requests. */
  close(): void;
}

/** Connect to a running daemon's control socket. Rejects if none is listening. */
export function connectControlClient(socketPath: string): Promise<ControlClient> {
  return new Promise((resolve, reject) => {
    const sock: Socket = connect(socketPath);
    const buf = new LineBuffer();
    const pending = new Map<
      string,
      { resolve: (res: ControlResponse) => void; reject: (err: Error) => void }
    >();
    let seq = 0;
    let closed = false;

    const failAll = (err: Error) => {
      for (const { reject: rejectPending } of pending.values()) rejectPending(err);
      pending.clear();
    };

    sock.on("connect", () => {
      resolve({
        request(verb, args) {
          return new Promise((res, rej) => {
            if (closed) return rej(new Error("control client closed"));
            const id = `c${++seq}`;
            pending.set(id, { resolve: res as (r: ControlResponse) => void, reject: rej });
            const msg = args === undefined ? { id, verb } : { id, verb, args };
            sock.write(encodeMessage(msg));
          });
        },
        close() {
          closed = true;
          failAll(new Error("control client closed"));
          sock.destroy();
        },
      });
    });

    sock.on("data", (chunk) => {
      let lines: string[];
      try {
        lines = buf.push(chunk.toString());
      } catch (err) {
        // Overflow (a daemon streaming an unbounded line) is unrecoverable:
        // fail all in-flight requests and tear the socket down.
        closed = true;
        failAll(err as Error);
        sock.destroy();
        return;
      }
      for (const line of lines) {
        if (line.length === 0) continue;
        const res = decodeResponse(line);
        if (!res) continue;
        const entry = pending.get(res.id);
        if (entry) {
          pending.delete(res.id);
          entry.resolve(res);
        }
      }
    });

    sock.on("error", (err: Error) => {
      reject(err); // no-op if already connected+resolved
      failAll(err);
    });

    sock.on("close", () => {
      closed = true;
      failAll(new Error("control socket closed"));
    });
  });
}
