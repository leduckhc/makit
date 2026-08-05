/**
 * Loopback HTTP bridge for agent connectors (e.g. a `makit-<agent>.ts` in
 * `server/connectors/`, and the keyless e2e harness's StubAdapter).
 *
 * Listens on 127.0.0.1:<random> and exposes two endpoints:
 *
 *   POST /uicall
 *   { sessionId, kind: "askUserQuestion" | "confirmAction", ... }
 *
 * Forwards the canonical UICall to `askDevice`, waits for the user's choice,
 * and returns the UIResponse as JSON.
 *
 *   POST /usage
 *   { sessionId, usage: { contextTokens?, contextWindow?, totals?, cost? } }
 *
 * Reports a context/cost snapshot (SPEC-37). Exists because pi reports no usage
 * over ACP at all, so `.pi/extensions/pi-usage` reads `ctx.getContextUsage()`
 * in-process and pushes it here. Fire-and-forget: the reply is an empty 200.
 *
 * The url + a short-lived token are injected into each spawned agent connector
 * via environment variables (MAKIT_BRIDGE_URL, MAKIT_BRIDGE_TOKEN). The
 * connector picks them up at load time and POSTs here when it needs a UI.
 */

import { createServer, type Server, type ServerResponse } from "node:http";
import { randomBytes } from "node:crypto";
import type { UICall, UIResponse } from "./uicall.js";
import type { SessionUsageDTO, SessionUsageTotals } from "./protocol.js";

export interface BridgeOpts {
  askDevice: (body: UICall & { sessionId?: string }) => Promise<UIResponse>;
  /**
   * Receives a validated usage snapshot from an agent-side extension (SPEC-37).
   * Absent = the endpoint still authenticates and validates but discards the
   * snapshot (the keyless e2e harnesses have no session store to feed).
   */
  onUsage?: (sessionId: string, usage: SessionUsageDTO) => void;
}

export interface BridgeHandle {
  url: string;
  token: string;
  stop: () => Promise<void>;
}

export async function startBridge(opts: BridgeOpts): Promise<BridgeHandle> {
  const token = randomBytes(16).toString("hex");

  const http: Server = createServer((req, res) => {
    const path = req.url;
    if (req.method !== "POST" || (path !== "/uicall" && path !== "/usage")) {
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
        if (path === "/usage") {
          handleUsage(JSON.parse(raw), opts.onUsage, res);
          return;
        }
        const body = JSON.parse(raw) as UICall & { sessionId?: string };
        const sessionId = typeof body.sessionId === "string" ? body.sessionId : undefined;
        const uiCall: UICall = { ...body };
        delete (uiCall as any).sessionId;
        const resp = await opts.askDevice({ ...uiCall, sessionId });
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify(resp));
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
  console.log(`[makit] uicall bridge listening on ${url}`);

  return {
    url,
    token,
    stop: () => new Promise<void>((r) => http.close(() => r())),
  };
}

/** Keep a finite number, drop anything else. */
function num(v: unknown): number | undefined {
  return typeof v === "number" && Number.isFinite(v) ? v : undefined;
}

/** Copy only the numeric total fields; an all-empty result becomes `undefined`. */
function totalsOf(v: unknown): SessionUsageTotals | undefined {
  if (typeof v !== "object" || v === null) return undefined;
  const t = v as Record<string, unknown>;
  const out: SessionUsageTotals = {};
  for (const k of ["total", "input", "cachedInput", "cacheWrite", "output", "reasoning"] as const) {
    const n = num(t[k]);
    if (n !== undefined) out[k] = n;
  }
  return Object.keys(out).length ? out : undefined;
}

/**
 * Validate and forward `POST /usage` (SPEC-37).
 *
 * The sender is an ordinary user-editable pi extension, so nothing here is
 * trusted: non-numeric fields are DROPPED rather than coerced (a `NaN%` in the
 * UI is worse than an absent reading), `measuredAt` is stamped server-side so a
 * skewed agent clock cannot make a snapshot look newer than it is, and a body
 * carrying no usable number at all is a 400 rather than an empty snapshot that
 * would overwrite a good one.
 */
function handleUsage(
  body: unknown,
  onUsage: BridgeOpts["onUsage"],
  res: ServerResponse,
): void {
  const b = (typeof body === "object" && body !== null ? body : {}) as Record<string, unknown>;
  const sessionId = typeof b.sessionId === "string" ? b.sessionId : "";
  const raw = (typeof b.usage === "object" && b.usage !== null ? b.usage : {}) as Record<string, unknown>;

  const contextTokens = num(raw.contextTokens);
  const contextWindow = num(raw.contextWindow);
  const totals = totalsOf(raw.totals);
  const rawCost = (typeof raw.cost === "object" && raw.cost !== null ? raw.cost : {}) as Record<string, unknown>;
  const amount = num(rawCost.amount);
  const cost =
    amount !== undefined && typeof rawCost.currency === "string"
      ? { amount, currency: rawCost.currency }
      : undefined;

  if (!sessionId || (contextTokens === undefined && contextWindow === undefined && !totals && !cost)) {
    res.writeHead(400, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "usage: need a sessionId and at least one reading" }));
    return;
  }

  onUsage?.(sessionId, {
    ...(contextTokens !== undefined ? { contextTokens } : {}),
    ...(contextWindow !== undefined ? { contextWindow } : {}),
    ...(totals ? { totals } : {}),
    ...(cost ? { cost } : {}),
    measuredAt: Date.now(),
  });
  res.writeHead(200).end();
}
