import { test } from "node:test";
import assert from "node:assert/strict";

import { chooseBindHost } from "./cert.js";

test("tailscale up → binds the tailnet IP (private, LAN irrelevant)", () => {
  const d = chooseBindHost({
    allowLan: true,
    tailscaleIp: () => "100.119.58.97",
    lans: () => ["192.168.1.10"],
  });
  assert.deepEqual(d, { host: "100.119.58.97", mode: "tailscale" });
});

test("no tailscale + --lan → binds first LAN IPv4 (explicit opt-in)", () => {
  const d = chooseBindHost({
    allowLan: true,
    tailscaleIp: () => null,
    lans: () => ["192.168.1.10", "10.0.0.5"],
  });
  assert.deepEqual(d, { host: "192.168.1.10", mode: "lan" });
});

test("no tailscale, no --lan → loopback only even when LANs exist", () => {
  const d = chooseBindHost({
    allowLan: false,
    tailscaleIp: () => null,
    lans: () => ["192.168.1.10"],
  });
  assert.deepEqual(d, { host: "127.0.0.1", mode: "loopback" });
});

test("no tailscale + --lan but no LAN present → loopback", () => {
  const d = chooseBindHost({
    allowLan: true,
    tailscaleIp: () => null,
    lans: () => [],
  });
  assert.deepEqual(d, { host: "127.0.0.1", mode: "loopback" });
});
