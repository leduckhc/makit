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
import { homedir } from "node:os";
import { join } from "node:path";
import { randomBytes, randomUUID, createHash, timingSafeEqual } from "node:crypto";
function makitHome() {
    return process.env.MAKIT_HOME || join(homedir(), ".makit");
}
function devicesPath() {
    return join(makitHome(), "devices.json");
}
export class DeviceRegistry {
    devices = new Map();
    byBearer = new Map();
    pendingTokens = new Map();
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
                const arr = JSON.parse(readFileSync(path, "utf8"));
                for (const d of arr) {
                    this.devices.set(d.id, d);
                    this.byBearer.set(d.bearer, d);
                }
            }
            catch {
                // Corrupted; start fresh.
            }
        }
    }
    /** Mint a short-lived pairing token (used in QR). */
    mintPairToken(ttlMs = 5 * 60 * 1000) {
        this.gcTokens();
        const token = randomBytes(16).toString("hex");
        this.pendingTokens.set(token, { token, expiresAt: Date.now() + ttlMs });
        return token;
    }
    /** Consume a pair token and create a new device. Returns the bearer. */
    consumePairToken(token, label) {
        this.gcTokens();
        const t = this.pendingTokens.get(token);
        if (!t)
            return null;
        this.pendingTokens.delete(token);
        const device = {
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
    authenticate(bearer) {
        const d = this.constantTimeLookup(bearer);
        if (!d)
            return null;
        d.lastSeenAt = Date.now();
        return d;
    }
    /**
     * Constant-time bearer lookup. Scans every known device (no early exit on a
     * Map hit, which would leak timing) and compares fixed-length SHA-256 digests
     * so `timingSafeEqual` never sees mismatched lengths.
     */
    constantTimeLookup(bearer) {
        const target = createHash("sha256").update(bearer).digest();
        let match = null;
        for (const d of this.byBearer.values()) {
            const candidate = createHash("sha256").update(d.bearer).digest();
            if (timingSafeEqual(target, candidate))
                match = d;
        }
        return match;
    }
    list() {
        return [...this.devices.values()];
    }
    /**
     * Persist a device's content-free wake push token (SPEC-07). No-op for an
     * unknown device. Written 0600 by {@link persist}.
     */
    setPushToken(deviceId, info) {
        const d = this.devices.get(deviceId);
        if (!d)
            return;
        d.pushToken = info.token;
        d.pushPlatform = info.platform;
        d.pushEnv = info.env;
        this.persist();
    }
    /**
     * Drop a device's push token (e.g. APNs reported it dead / unregistered)
     * while keeping the device paired. No-op for an unknown device.
     */
    clearPushToken(deviceId) {
        const d = this.devices.get(deviceId);
        if (!d || d.pushToken === undefined)
            return;
        delete d.pushToken;
        delete d.pushPlatform;
        delete d.pushEnv;
        this.persist();
    }
    revoke(deviceId) {
        const d = this.devices.get(deviceId);
        if (!d)
            return false;
        this.devices.delete(deviceId);
        this.byBearer.delete(d.bearer);
        this.persist();
        return true;
    }
    gcTokens() {
        const now = Date.now();
        for (const [k, v] of this.pendingTokens) {
            if (v.expiresAt < now)
                this.pendingTokens.delete(k);
        }
    }
    persist() {
        writeFileSync(devicesPath(), JSON.stringify([...this.devices.values()], null, 2), {
            mode: 0o600,
        });
    }
}
//# sourceMappingURL=registry.js.map