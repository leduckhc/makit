/**
 * `makit qr [--refresh] [--url-only]`
 *
 * Fetches the active pair token from the running daemon and renders a QR code
 * in the terminal. With `--refresh` it mints a fresh token first. With
 * `--url-only` it prints only the URL (suitable for scripting).
 *
 * Token minting always goes through the daemon so the running server honours
 * the token — we never duplicate the minting logic client-side.
 */

import qrcode from "qrcode-terminal";
import { requireDaemon } from "./require-daemon.js";
import { controlSocketPath } from "../daemon/paths.js";
import type { PairMintData, PairCurrentData } from "../daemon/protocol.js";

interface QrArgs {
  refresh: boolean;
  urlOnly: boolean;
}

export function parseQrArgs(argv: string[]): QrArgs {
  return {
    refresh: argv.includes("--refresh"),
    urlOnly: argv.includes("--url-only"),
  };
}

export async function runQr(argv: string[]): Promise<void> {
  const args = parseQrArgs(argv);
  const client = await requireDaemon(controlSocketPath());

  try {
    let url: string;
    let fingerprint: string | undefined;
    let expiresAt: number | undefined;

    if (args.refresh) {
      const res = await client.request<PairMintData>("pair.mint");
      if (!res.ok) {
        console.error(`[makit] pair.mint failed: ${res.error}`);
        process.exit(1);
      }
      url = res.data!.url;
      fingerprint = res.data!.fingerprint;
      expiresAt = res.data!.expiresAt;
    } else {
      // Try current first; fall back to minting if none active.
      const currentRes = await client.request<PairCurrentData | null>("pair.current");
      if (currentRes.ok && currentRes.data) {
        url = currentRes.data.url;
        expiresAt = currentRes.data.expiresAt;
      } else {
        const mintRes = await client.request<PairMintData>("pair.mint");
        if (!mintRes.ok) {
          console.error(`[makit] pair.mint failed: ${mintRes.error}`);
          process.exit(1);
        }
        url = mintRes.data!.url;
        fingerprint = mintRes.data!.fingerprint;
        expiresAt = mintRes.data!.expiresAt;
      }
    }

    if (args.urlOnly) {
      process.stdout.write(url + "\n");
      return;
    }

    console.log("");
    qrcode.generate(url, { small: true });
    console.log(`[makit] ${url}`);
    if (fingerprint) console.log(`[makit] fingerprint: ${fingerprint}`);
    if (expiresAt) {
      const secsLeft = Math.max(0, Math.round((expiresAt - Date.now()) / 1000));
      console.log(`[makit] (expires in ~${secsLeft}s)`);
    }
    console.log("");
  } finally {
    client.close();
  }
}
