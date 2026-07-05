/**
 * `pino devices`              — list paired devices
 * `pino devices revoke <id>` — revoke a device by id
 *
 * Both are thin clients of the daemon's control socket (SPEC-02).
 */

import { requireDaemon } from "./require-daemon.js";
import { controlSocketPath } from "../daemon/paths.js";
import type { DevicesListData, DevicesRevokeData } from "../daemon/protocol.js";

export async function runDevices(argv: string[]): Promise<void> {
  const sub = argv[0];

  if (sub === "revoke") {
    const id = argv[1];
    if (!id) {
      console.error("usage: pino devices revoke <id>");
      process.exit(2);
    }
    const client = await requireDaemon(controlSocketPath());
    try {
      const res = await client.request<DevicesRevokeData>("devices.revoke", { id });
      if (!res.ok) {
        console.error(`[pino] devices.revoke failed: ${res.error}`);
        process.exit(1);
      }
      if (res.data!.removed) {
        console.log(`[pino] device ${id} revoked`);
      } else {
        console.error(`[pino] device ${id} not found`);
        process.exit(1);
      }
    } finally {
      client.close();
    }
    return;
  }

  const client = await requireDaemon(controlSocketPath());
  try {
    const res = await client.request<DevicesListData>("devices.list");
    if (!res.ok) {
      console.error(`[pino] devices.list failed: ${res.error}`);
      process.exit(1);
    }
    const { devices } = res.data!;
    if (devices.length === 0) {
      console.log("no paired devices");
      return;
    }
    for (const d of devices) {
      const status = d.connected ? " [connected]" : "";
      const paired = new Date(d.pairedAt).toISOString();
      console.log(`${d.id}  ${d.label}${status}  (paired ${paired})`);
    }
  } finally {
    client.close();
  }
}
