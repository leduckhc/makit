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
import { execFileSync } from "node:child_process";
import selfsigned from "selfsigned";

function makitHome(): string {
  return process.env.MAKIT_HOME || join(homedir(), ".makit");
}

function certPath(): string {
  return join(makitHome(), "server.crt");
}

function keyPath(): string {
  return join(makitHome(), "server.key");
}

export interface ServerCert {
  cert: string;       // PEM
  key: string;        // PEM
  /** sha256 fingerprint of the DER cert, lowercase hex with no separators. */
  fingerprint: string;
}

export async function loadOrCreateCert(): Promise<ServerCert> {
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
    { type: 2 as const, value: "localhost" }, // DNS
    { type: 7 as const, ip: "127.0.0.1" }, // IP
    ...allIps.map((ip) => ({ type: 7 as const, ip })),
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

/**
 * Candidate locations for the `tailscale` CLI, tried in order.
 *
 * A bare `tailscale` only works when the binary is on the process `PATH`.
 * GUI-launched apps on macOS (the packaged desktop app that spawns this
 * server) inherit a minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`) that omits
 * Homebrew and the Tailscale.app bundle, so a bare spawn fails with `ENOENT`
 * even when Tailscale is installed and up — which is why the server fell back
 * to loopback despite Tailscale running. Probe the well-known install paths
 * too so detection survives a stripped `PATH`.
 */
export const TAILSCALE_BINARIES: readonly string[] = [
  "tailscale",
  "/usr/local/bin/tailscale",
  "/opt/homebrew/bin/tailscale",
  "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
];

/**
 * Runs a `tailscale` subcommand and returns its stdout, or throws if the binary
 * is missing / the command fails. Injectable so [tailscaleIP] is unit-testable
 * without a real CLI on the machine.
 */
export type TailscaleRunner = (bin: string, args: string[]) => string;

const defaultTailscaleRunner: TailscaleRunner = (bin, args) =>
  execFileSync(bin, args, {
    encoding: "utf8",
    timeout: 2000,
    stdio: ["ignore", "pipe", "ignore"],
    // The macOS app-bundle executable guesses GUI vs CLI from terminal
    // environment variables. A packaged GUI app has none, so force CLI mode;
    // harmless for standalone/Homebrew binaries.
    env: { ...process.env, TAILSCALE_BE_CLI: "1" },
  });

/**
 * Detect this machine's Tailscale IPv4 (`100.x`) address, or null if Tailscale
 * isn't installed / isn't up.
 *
 * Uses `tailscale ip -4` (cheaper and more direct than parsing
 * `tailscale status --json`) and tries each candidate in [TAILSCALE_BINARIES]
 * so detection works even when the CLI isn't on a GUI-launched server's
 * minimal `PATH`.
 */
export function tailscaleIP(run: TailscaleRunner = defaultTailscaleRunner): string | null {
  for (const bin of TAILSCALE_BINARIES) {
    try {
      const out = run(bin, ["ip", "-4"]);
      const ip = out
        .split(/\r?\n/)
        .map((line) => line.trim())
        .find((line) => line.startsWith("100."));
      if (ip) return ip;
    } catch {
      // Not found at this path (ENOENT) or the command failed — try the next.
    }
  }
  return null; // offline or tailscale not installed
}

/**
 * Best external bind host: Tailscale if online, else the first non-internal
 * LAN IPv4. This is the default — binding here keeps the server off `0.0.0.0`
 * so we don't expose port 8787 to every interface the machine joins (public
 * Wi-Fi, corporate networks, …). A separate loopback listener (see
 * `startWsServer`) still handles the loopback HTTP bridge and the
 * `flutter run -d macos` dev loop.
 *
 * Users can override via `--host 0.0.0.0` if they need every interface.
 */
export type BindMode = "tailscale" | "lan" | "loopback";

export interface BindDecision {
  host: string;
  mode: BindMode;
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
export function chooseBindHost(
  opts: {
    allowLan?: boolean;
    tailscaleIp?: () => string | null;
    lans?: () => string[];
  } = {},
): BindDecision {
  const ts = (opts.tailscaleIp ?? tailscaleIP)();
  if (ts) return { host: ts, mode: "tailscale" };
  if (opts.allowLan) {
    const lan = (opts.lans ?? localIPv4s)()[0];
    if (lan) return { host: lan, mode: "lan" };
  }
  return { host: "127.0.0.1", mode: "loopback" };
}
