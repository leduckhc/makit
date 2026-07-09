/**
 * Loopback HTTP bridge for agent connectors (makit-pi, makit-codex, etc.).
 *
 * Listens on 127.0.0.1:<random> and exposes a single endpoint:
 *
 *   POST /uicall
 *   { sessionId, kind: "askUserQuestion" | "confirmAction", ... }
 *
 * Forwards the canonical UICall to `askDevice`, waits for the user's choice,
 * and returns the UIResponse as JSON.
 *
 * The url + a short-lived token are injected into each spawned agent connector
 * via environment variables (MAKIT_BRIDGE_URL, MAKIT_BRIDGE_TOKEN). The
 * connector picks them up at load time and POSTs here when it needs a UI.
 */
import { createServer } from "node:http";
import { randomBytes } from "node:crypto";
export async function startBridge(opts) {
    const token = randomBytes(16).toString("hex");
    const http = createServer((req, res) => {
        if (req.method !== "POST" || req.url !== "/uicall") {
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
                const body = JSON.parse(raw);
                const sessionId = typeof body.sessionId === "string" ? body.sessionId : undefined;
                const uiCall = { ...body };
                delete uiCall.sessionId;
                const resp = await opts.askDevice({ ...uiCall, sessionId });
                res.writeHead(200, { "content-type": "application/json" });
                res.end(JSON.stringify(resp));
            }
            catch (e) {
                res.writeHead(500, { "content-type": "application/json" });
                res.end(JSON.stringify({ error: e.message }));
            }
        });
    });
    await new Promise((resolve) => http.listen(0, "127.0.0.1", resolve));
    const addr = http.address();
    if (!addr || typeof addr === "string")
        throw new Error("bridge: bad address");
    const url = `http://127.0.0.1:${addr.port}`;
    console.log(`[makit] uicall bridge listening on ${url}`);
    return {
        url,
        token,
        stop: () => new Promise((r) => http.close(() => r())),
    };
}
//# sourceMappingURL=bridge.js.map