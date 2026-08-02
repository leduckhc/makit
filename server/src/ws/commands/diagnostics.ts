/**
 * Client diagnostics ingestion: the `client.log`
 * `cmd` handler.
 *
 * A paired device (especially iOS, whose console is unreachable in the field)
 * ships batches of its own log records here — framework assertions, uncaught
 * errors, connection breadcrumbs. Each record is written to the shared server
 * logger, so it lands in `~/.makit/makit.log` and is already surfaced by the
 * daemon's live tail (the desktop `SessionLogScreen`) and the `makit logs` CLI
 * with no new retrieval plumbing.
 *
 * The device identity comes from the authed connection, not the wire, so a
 * client cannot spoof another device's label.
 */

import { log } from "../../log.js";
import type { CommandRouter } from "../command_router.js";

/** Never process more than this many records from a single batch. */
const MAX_RECORDS = 1000;

interface ClientRecord {
  ts?: unknown;
  level?: unknown;
  tag?: unknown;
  message?: unknown;
}

export function register(r: CommandRouter): void {
  r.register("client.log", (ctx) => {
    const platform = String(ctx.env.platform ?? "unknown");
    const who = ctx.client.deviceLabel ?? ctx.client.deviceId ?? "unknown";
    const raw = Array.isArray(ctx.env.records) ? (ctx.env.records as ClientRecord[]) : [];
    const records = raw.slice(0, MAX_RECORDS);
    for (const rec of records) {
      const level = String(rec?.level ?? "info").toUpperCase();
      const tag = String(rec?.tag ?? "");
      const message = String(rec?.message ?? "");
      // Always emit at `info` so the client's own severity survives in the text
      // without being dropped by the server's level gate.
      log.info(`[client:${platform}:${who}] ${level} [${tag}] ${message}`);
    }
    ctx.ack({ received: records.length });
  });
}
