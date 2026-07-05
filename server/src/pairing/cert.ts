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
import { execSync } from "node:child_process";
import selfsigned from "selfsigned";

function pinoHome(): string {
  return process.env.PINO_HOME || join(homedir(), ".pino");
}

function certPath(): string {
  return join(pinoHome(), "server.crt");
}

function keyPath(): string {
  return join(pinoHome(), "server.key");
}

export interface ServerCert {
  cert: string;       // PEM
  key: string;        // PEM
  /** sha256 fingerprint of the DER cert, lowercase hex with no separators. */
  fingerprint: string;
}

export async function loadOrCreateCert(): Promise<ServerCert> {
  mkdirSync(pinoHome(), { recursive: true });
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
    { type: 2 as const, value: "localhost" }, // DNS
    { type: 7 as const, ip: "127.0.0.1" }, // IP
    ...allIps.map((ip) => ({ type: 7 as const, ip })),
  ];

  const attrs = [{ name: "commonName", value: "pino" }];
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

export function fingerprintOf(pemCert: string): string {
  const x = new X509Certificate(pemCert);
  return createHash("sha256").update(x.raw).digest("hex");
}

export function localIPv4s(): string[] {
  const ifs = networkInterfaces();
  const out: string[] = [];
  for (const list of Object.values(ifs)) {
    for (const i of list ?? []) {
      if (i.family === "IPv4" && !i.internal) out.push(i.address);
    }
  }
  return out;
}

/** Detect Tailscale IP (100.x.x.x) if online. Returns null if offline. */
export function tailscaleIP(): string | null {
  try {
    const output = execSync("tailscale status --json", { encoding: "utf8", timeout: 2000 });
    const status = JSON.parse(output) as { Self?: { TailscaleIPs?: string[] } };
    const ips = status.Self?.TailscaleIPs ?? [];
    const tailscaleIp = ips.find((ip) => ip.startsWith("100."));
    return tailscaleIp ?? null;
  } catch {
    return null; // offline or tailscale not installed
  }
}
