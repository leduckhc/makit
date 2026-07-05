/**
 * `pino status`
 *
 * Pretty-prints the daemon's `status` verb response: pid, host:port,
 * fingerprint, advertise host, paired devices, running sessions, uptime.
 * Exits 3 if the daemon is not running.
 */

import { requireDaemon } from "./require-daemon.js";
import { controlSocketPath } from "../daemon/paths.js";
import type { StatusData } from "../daemon/protocol.js";

function fmtUptime(ms: number): string {
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ${s % 60}s`;
  const h = Math.floor(m / 60);
  return `${h}h ${m % 60}m`;
}

export async function runStatus(argv: string[]): Promise<void> {
  void argv;
  const client = await requireDaemon(controlSocketPath());
  try {
    const res = await client.request<StatusData>("status");
    if (!res.ok) {
      console.error(`[pino] status failed: ${res.error}`);
      process.exit(1);
    }
    const d = res.data!;
    const advertise = d.advertiseHost ? `  advertise host : ${d.advertiseHost}\n` : "";
    console.log(
      `pino v${d.version}\n` +
      `  pid            : ${d.pid}\n` +
      `  listen         : ${d.host}:${d.port}\n` +
      advertise +
      `  fingerprint    : ${d.fingerprint}\n` +
      `  paired devices : ${d.pairedDevices}\n` +
      `  running sessions: ${d.runningSessions}\n` +
      `  uptime         : ${fmtUptime(d.uptimeMs)}`,
    );
  } finally {
    client.close();
  }
}
