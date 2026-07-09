/**
 * Self-signed cert + key for the makit server.
 *
 * Stored in `~/.makit/server.{crt,key}` and regenerated only if missing.
 * Fingerprint (sha256 of DER) is what the QR carries and the app pins.
 */
import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { homedir, networkInterfaces } from "node:os";
import { join } from "node:path";
import { createHash, X509Certificate } from "node:crypto";
import { execSync } from "node:child_process";
import selfsigned from "selfsigned";
function makitHome() {
    return process.env.MAKIT_HOME || join(homedir(), ".makit");
}
function certPath() {
    return join(makitHome(), "server.crt");
}
function keyPath() {
    return join(makitHome(), "server.key");
}
export async function loadOrCreateCert() {
    mkdirSync(makitHome(), { recursive: true });
    const crtPath = certPath();
    const keyFilePath = keyPath();
    if (existsSync(crtPath) && existsSync(keyFilePath)) {
        const cert = readFileSync(crtPath, "utf8");
        const key = readFileSync(keyFilePath, "utf8");
        return { cert, key, fingerprint: fingerprintOf(cert) };
    }
    // 10-year self-signed cert with Tailscale IP (if available), LAN IPs, and localhost as SAN.
    const ips = localIPv4s();
    const tailscaleIp = tailscaleIP();
    const allIps = tailscaleIp ? [tailscaleIp, ...ips] : ips;
    const altNames = [
        { type: 2, value: "localhost" }, // DNS
        { type: 7, ip: "127.0.0.1" }, // IP
        ...allIps.map((ip) => ({ type: 7, ip })),
    ];
    const attrs = [{ name: "commonName", value: "makit" }];
    const pems = await selfsigned.generate(attrs, {
        keySize: 2048,
        notAfterDate: new Date(Date.now() + 3650 * 24 * 60 * 60 * 1000), // ~10y
        algorithm: "sha256",
        extensions: [
            { name: "basicConstraints", cA: false },
            {
                name: "keyUsage",
                keyCertSign: false,
                digitalSignature: true,
                keyEncipherment: true,
            },
            { name: "extKeyUsage", serverAuth: true },
            { name: "subjectAltName", altNames },
        ],
    });
    writeFileSync(crtPath, pems.cert, { mode: 0o600 });
    writeFileSync(keyFilePath, pems.private, { mode: 0o600 });
    return { cert: pems.cert, key: pems.private, fingerprint: fingerprintOf(pems.cert) };
}
export function fingerprintOf(pemCert) {
    const x = new X509Certificate(pemCert);
    return createHash("sha256").update(x.raw).digest("hex");
}
export function localIPv4s() {
    const ifs = networkInterfaces();
    const out = [];
    for (const list of Object.values(ifs)) {
        for (const i of list ?? []) {
            if (i.family === "IPv4" && !i.internal)
                out.push(i.address);
        }
    }
    return out;
}
/** Detect Tailscale IP (100.x.x.x) if online. Returns null if offline. */
export function tailscaleIP() {
    try {
        const output = execSync("tailscale status --json", { encoding: "utf8", timeout: 2000 });
        const status = JSON.parse(output);
        const ips = status.Self?.TailscaleIPs ?? [];
        const tailscaleIp = ips.find((ip) => ip.startsWith("100."));
        return tailscaleIp ?? null;
    }
    catch {
        return null; // offline or tailscale not installed
    }
}
/**
 * Secure-by-default bind host decision.
 *
 * - Tailscale up → its `100.x` tailnet IP (private WireGuard overlay). This is
 *   the recommended transport: works off-LAN and never exposes a socket on an
 *   untrusted network.
 * - else if `allowLan` (explicit `--lan`) → the first non-internal LAN IPv4.
 *   This exposes port 8787 to every device on the local network — unsafe on
 *   public Wi-Fi — so it's opt-in, never the default.
 * - else → loopback only (`127.0.0.1`): not reachable from other devices. The
 *   caller should print guidance recommending Tailscale.
 *
 * `tailscaleIp`/`lans` are injectable so the decision is unit-testable without
 * shelling out to `tailscale` or reading real interfaces.
 */
export function chooseBindHost(opts = {}) {
    const ts = (opts.tailscaleIp ?? tailscaleIP)();
    if (ts)
        return { host: ts, mode: "tailscale" };
    if (opts.allowLan) {
        const lan = (opts.lans ?? localIPv4s)()[0];
        if (lan)
            return { host: lan, mode: "lan" };
    }
    return { host: "127.0.0.1", mode: "loopback" };
}
//# sourceMappingURL=cert.js.map