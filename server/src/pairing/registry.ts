/**
 * Pairing tokens and device registry.
 *
 * Two kinds of secrets:
 *  - **Pair tokens**: short-lived (5 min), single-use, embedded in the QR.
 *    The phone presents one in its first `hello`; on success we mint a
 *    bearer token and persist the device.
 *  - **Bearer tokens**: long-lived, per-device. Stored in
 *    `~/.pino/devices.json`. Phone sends one on every subsequent connect.
 */

import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { randomBytes, randomUUID } from "node:crypto";

function pinoHome(): string {
  return process.env.PINO_HOME || join(homedir(), ".pino");
}

function devicesPath(): string {
  return join(pinoHome(), "devices.json");
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
}

export class DeviceRegistry {
  private devices = new Map<string, PairedDevice>();
  private byBearer = new Map<string, PairedDevice>();
  private pendingTokens = new Map<string, PairToken>();

  constructor() {
    mkdirSync(pinoHome(), { recursive: true });
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

  /** Look up a paired device by its bearer token. */
  authenticate(bearer: string): PairedDevice | null {
    const d = this.byBearer.get(bearer);
    if (!d) return null;
    d.lastSeenAt = Date.now();
    return d;
  }

  list(): PairedDevice[] {
    return [...this.devices.values()];
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
