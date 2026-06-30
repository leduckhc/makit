/**
 * Self-signed cert + key for the pino server.
 *
 * Stored in `~/.pino/server.{crt,key}` and regenerated only if missing.
 * Fingerprint (sha256 of DER) is what the QR carries and the app pins.
 */
import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { homedir, networkInterfaces } from "node:os";
import { join } from "node:path";
import { createHash, X509Certificate } from "node:crypto";
import selfsigned from "selfsigned";
const PINO_DIR = join(homedir(), ".pino");
const CRT_PATH = join(PINO_DIR, "server.crt");
const KEY_PATH = join(PINO_DIR, "server.key");
export function loadOrCreateCert() {
    mkdirSync(PINO_DIR, { recursive: true });
    if (existsSync(CRT_PATH) && existsSync(KEY_PATH)) {
        const cert = readFileSync(CRT_PATH, "utf8");
        const key = readFileSync(KEY_PATH, "utf8");
        return { cert, key, fingerprint: fingerprintOf(cert) };
    }
    // 10-year self-signed cert with all local LAN IPs as SAN so wss:// works
    // when the app dials the server by IP from a phone.
    const ips = localIPv4s();
    const altNames = [
        { type: 2, value: "localhost" }, // DNS
        { type: 7, ip: "127.0.0.1" }, // IP
        ...ips.map((ip) => ({ type: 7, ip })),
    ];
    const attrs = [{ name: "commonName", value: "pino" }];
    const pems = selfsigned.generate(attrs, {
        keySize: 2048,
        days: 3650,
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
    writeFileSync(CRT_PATH, pems.cert, { mode: 0o600 });
    writeFileSync(KEY_PATH, pems.private, { mode: 0o600 });
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
//# sourceMappingURL=cert.js.map