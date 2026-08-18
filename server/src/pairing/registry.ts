/**
 * Pairing tokens and device registry.
 *
 * Two kinds of secrets:
 *  - **Pair tokens**: short-lived (5 min), single-use, embedded in the QR.
 *    The phone presents one in its first `hello`; on success we mint a
 *    bearer token and persist the device.
 *  - **Bearer tokens**: long-lived, per-device. Stored in
 *    `~/.makit/devices.json`. Phone sends one on every subsequent connect.
 */

import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { homedir, hostname } from "node:os";
import { join } from "node:path";
import { randomBytes, randomUUID, createHash, timingSafeEqual } from "node:crypto";

import type { DeviceCap } from "../protocol.js";

function makitHome(): string {
  return process.env.MAKIT_HOME || join(homedir(), ".makit");
}

function devicesPath(): string {
  return join(makitHome(), "devices.json");
}

interface PairToken {
  token: string;
  expiresAt: number;
}

export interface PairedDevice {
  id: string;
  label: string;
  /** Long-lived bearer token (random 32 bytes, hex). */
  bearer: string;
  pairedAt: number;
  lastSeenAt: number;
  /** Content-free wake push token (SPEC-background-wake-notifications). Cleared on 410/BadDeviceToken. */
  pushToken?: string;
  /** Push routing platform: "apns" | "fcm". */
  pushPlatform?: string;
  /** APNs environment for the token: "sandbox" | "production". */
  pushEnv?: string;
  /**
   * SPEC-cli-as-client (D2): what this device may do. **Absent means full access**, which
   * is what every device paired before SPEC-cli-as-client is — the field is additive and
   * must never retroactively restrict an existing phone. `cli@<host>` is minted
   * with `["client"]` so it is a separately revocable subject.
   */
  caps?: DeviceCap[];
}

export class DeviceRegistry {
  private devices = new Map<string, PairedDevice>();
  private byBearer = new Map<string, PairedDevice>();
  private pendingTokens = new Map<string, PairToken>();

  // NOTE: brute-forcing a 128-bit pair token is infeasible, so there is no
  // registry-level attempt lockout — a global counter here would let any LAN
  // peer's bad guesses block the legitimate phone's *valid* token (a local
  // DoS). Abuse throttling, if ever needed, belongs at the connection layer
  // (WS `hello` handler, where the source IP is available).

  constructor() {
    mkdirSync(makitHome(), { recursive: true });
    const path = devicesPath();
    if (existsSync(path)) {
      try {
        const arr = JSON.parse(readFileSync(path, "utf8")) as PairedDevice[];
        for (const d of arr) {
          this.devices.set(d.id, d);
          this.byBearer.set(d.bearer, d);
        }
      } catch {
        // Corrupted; start fresh.
      }
    }
  }

  /** Mint a short-lived pairing token (used in QR). */
  mintPairToken(ttlMs = 5 * 60 * 1000): string {
    this.gcTokens();
    const token = randomBytes(16).toString("hex");
    this.pendingTokens.set(token, { token, expiresAt: Date.now() + ttlMs });
    return token;
  }

  /** Consume a pair token and create a new device. Returns the bearer. */
  consumePairToken(token: string, label: string): PairedDevice | null {
    this.gcTokens();
    const t = this.pendingTokens.get(token);
    if (!t) return null;
    this.pendingTokens.delete(token);
    const device: PairedDevice = {
      id: randomUUID(),
      label: label || "device",
      bearer: randomBytes(32).toString("hex"),
      pairedAt: Date.now(),
      lastSeenAt: Date.now(),
    };
    this.devices.set(device.id, device);
    this.byBearer.set(device.bearer, device);
    this.persist();
    return device;
  }

  /**
   * SPEC-cli-as-client (D2): mint (or return) the CLI's own device — label `cli@<hostname>`
   * with `caps: ["client"]`, so it is a subject that is revocable separately
   * from the user's phone. Idempotent by label: a second call returns the SAME
   * device with `created: false`, so a CLI whose `~/.makit/cli.json` cache was
   * lost does not mint a second row that would clutter `makit devices`.
   */
  grantCli(): { device: PairedDevice; created: boolean } {
    const label = `cli@${hostname()}`;
    for (const d of this.devices.values()) {
      if (d.label !== label) continue;
      // Idempotent in SHAPE as well as identity. This device is the subject every
      // capability gate reads, and an absent `caps` is FULL access by the
      // protocol's own rule (D2) — so a row that reached devices.json without one
      // (a hand edit, a pair token crafted with this label) would silently hand
      // the CLI more authority than D2 ever grants it. Repaired and persisted,
      // because otherwise the next process reads full access again.
      if (!d.caps) {
        d.caps = ["client"];
        this.persist();
      }
      return { device: d, created: false };
    }
    const device: PairedDevice = {
      id: randomUUID(),
      label,
      bearer: randomBytes(32).toString("hex"),
      pairedAt: Date.now(),
      lastSeenAt: Date.now(),
      caps: ["client"],
    };
    this.devices.set(device.id, device);
    this.byBearer.set(device.bearer, device);
    this.persist();
    return { device, created: true };
  }

  /** Look up a paired device by its bearer token. */
  authenticate(bearer: string): PairedDevice | null {
    const d = this.constantTimeLookup(bearer);
    if (!d) return null;
    d.lastSeenAt = Date.now();
    return d;
  }

  /**
   * Constant-time bearer lookup. Scans every known device (no early exit on a
   * Map hit, which would leak timing) and compares fixed-length SHA-256 digests
   * so `timingSafeEqual` never sees mismatched lengths.
   */
  private constantTimeLookup(bearer: string): PairedDevice | null {
    const target = createHash("sha256").update(bearer).digest();
    let match: PairedDevice | null = null;
    for (const d of this.byBearer.values()) {
      const candidate = createHash("sha256").update(d.bearer).digest();
      if (timingSafeEqual(target, candidate)) match = d;
    }
    return match;
  }

  list(): PairedDevice[] {
    return [...this.devices.values()];
  }

  /**
   * Persist a device's content-free wake push token (SPEC-background-wake-notifications). No-op for an
   * unknown device. Written 0600 by {@link persist}.
   */
  setPushToken(
    deviceId: string,
    info: { token: string; platform: string; env?: string },
  ): void {
    const d = this.devices.get(deviceId);
    if (!d) return;
    d.pushToken = info.token;
    d.pushPlatform = info.platform;
    d.pushEnv = info.env;
    this.persist();
  }

  /**
   * Drop a device's push token (e.g. APNs reported it dead / unregistered)
   * while keeping the device paired. No-op for an unknown device.
   */
  clearPushToken(deviceId: string): void {
    const d = this.devices.get(deviceId);
    if (!d || d.pushToken === undefined) return;
    delete d.pushToken;
    delete d.pushPlatform;
    delete d.pushEnv;
    this.persist();
  }

  revoke(deviceId: string): boolean {
    const d = this.devices.get(deviceId);
    if (!d) return false;
    this.devices.delete(deviceId);
    this.byBearer.delete(d.bearer);
    this.persist();
    return true;
  }

  private gcTokens() {
    const now = Date.now();
    for (const [k, v] of this.pendingTokens) {
      if (v.expiresAt < now) this.pendingTokens.delete(k);
    }
  }

  private persist() {
    writeFileSync(devicesPath(), JSON.stringify([...this.devices.values()], null, 2), {
      mode: 0o600,
    });
  }
}
