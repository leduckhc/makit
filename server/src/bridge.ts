/**
 * Loopback HTTP bridge for in-process pi extensions (and any other tool that
 * runs in a sibling process and needs to do reverse-RPC into the phone).
 *
 * Listens on 127.0.0.1:<random> and exposes a single endpoint:
 *
 *   POST /ask
 *   { sessionId, kind: "askUserQuestion", question, options, ... }
 *
 * Forwards the body verbatim to `askDevice` and returns the resolved response
 * envelope as JSON.
 *
 * The url + a short shared secret are passed to the spawned `pi --mode rpc`
 * via env vars (PINO_BRIDGE_URL, PINO_BRIDGE_TOKEN). The pino-pi extension
 * picks them up at load time.
 */

import { createServer, type Server } from "node:http";
import { randomBytes } from "node:crypto";
import type { Envelope } from "./protocol.js";

export interface BridgeOpts {
  askDevice: (body: Record<string, unknown>, opts?: { sessionId?: string; timeoutMs?: number }) => Promise<Envelope>;
}

export interface BridgeHandle {
  url: string;
  token: string;
  stop: () => Promise<void>;
}

export async function startBridge(opts: BridgeOpts): Promise<BridgeHandle> {
  const token = randomBytes(16).toString("hex");

  const http: Server = createServer((req, res) => {
    if (req.method !== "POST" || req.url !== "/ask") {
      res.writeHead(404).end();
      return;
    }
    if (req.headers.authorization !== `Bearer ${token}`) {
      res.writeHead(401).end();
      return;
    }
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", async () => {
      try {
        const body = JSON.parse(raw) as Record<string, unknown>;
        const sessionId = typeof body.sessionId === "string" ? body.sessionId : undefined;
        const timeoutMs = typeof body.timeoutMs === "number" ? body.timeoutMs : undefined;
        delete body.sessionId;
        delete body.timeoutMs;
        const resp = await opts.askDevice(body, { sessionId, timeoutMs });
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify(resp.body ?? {}));
      } catch (e) {
        res.writeHead(500, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: (e as Error).message }));
      }
    });
  });

  await new Promise<void>((resolve) => http.listen(0, "127.0.0.1", resolve));
  const addr = http.address();
  if (!addr || typeof addr === "string") throw new Error("bridge: bad address");
  const url = `http://127.0.0.1:${addr.port}`;
  console.log(`[pino] extension bridge listening on ${url}`);

  return {
    url,
    token,
    stop: () => new Promise<void>((r) => http.close(() => r())),
  };
}
