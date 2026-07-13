import { test } from "node:test";
import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { chooseBindHost, tailscaleIP, TAILSCALE_BINARIES } from "./cert.js";

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

test("tailscaleIP: parses `tailscale ip -4` output (trims trailing newline)", () => {
  const ip = tailscaleIP((bin, args) => {
    assert.deepEqual(args, ["ip", "-4"]);
    assert.equal(bin, "tailscale");
    return "100.119.58.97\n";
  });
  assert.equal(ip, "100.119.58.97");
});

test("tailscaleIP: falls back to a known path when `tailscale` isn't on PATH", () => {
  // Mirrors a GUI-launched server: the bare `tailscale` spawn fails with
  // ENOENT, but the binary exists at its Homebrew/App-bundle location.
  const tried: string[] = [];
  const ip = tailscaleIP((bin) => {
    tried.push(bin);
    if (bin === "tailscale") {
      const err = new Error("spawn tailscale ENOENT");
      throw err;
    }
    return "100.64.0.5\n";
  });
  assert.equal(ip, "100.64.0.5");
  // Probed the bare name first, then the next candidate.
  assert.equal(tried[0], "tailscale");
  assert.ok(TAILSCALE_BINARIES.includes(tried[1]!));
});

test("tailscaleIP: ignores non-tailnet lines", () => {
  const ip = tailscaleIP(() => "192.168.1.10\n");
  assert.equal(ip, null);
});

test("tailscaleIP: returns null when every candidate binary is missing", () => {
  const tried: string[] = [];
  const ip = tailscaleIP((bin) => {
    tried.push(bin);
    throw new Error("spawn ENOENT");
  });
  assert.equal(ip, null);
  // Every candidate was attempted before giving up.
  assert.equal(tried.length, TAILSCALE_BINARIES.length);
});

test("tailscaleIP: forces the macOS app executable into CLI mode", () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-tailscale-"));
  const bin = join(dir, "tailscale");
  writeFileSync(
    bin,
    '#!/bin/sh\n[ "$TAILSCALE_BE_CLI" = "1" ] || exit 1\necho 100.64.0.9\n',
  );
  chmodSync(bin, 0o755);

  const previousPath = process.env.PATH;
  process.env.PATH = dir;
  try {
    assert.equal(tailscaleIP(), "100.64.0.9");
  } finally {
    if (previousPath === undefined) delete process.env.PATH;
    else process.env.PATH = previousPath;
    rmSync(dir, { recursive: true, force: true });
  }
});
