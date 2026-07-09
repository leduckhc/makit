/**
 * mDNS advertisement of `_makit._tcp.local` so phones on the same Wi-Fi can
 * auto-discover the server. TXT carries the cert fingerprint and protocol
 * version so the app can corroborate the QR or skip QR entirely on trusted
 * networks.
 */

import { Bonjour, type Service } from "bonjour-service";

export interface MdnsOpts {
  port: number;
  fingerprint: string;
  hostLabel?: string;
}

export class MdnsAd {
  private bonjour = new Bonjour();
  private service?: Service;

  start(opts: MdnsOpts) {
    this.service = this.bonjour.publish({
      name: opts.hostLabel ?? `makit on ${process.env.USER ?? "host"}`,
      type: "makit",
      protocol: "tcp",
      port: opts.port,
      txt: {
        fp: opts.fingerprint,
        v: "1",
      },
    });
    // mDNS is a best-effort convenience (the app can still connect via the
    // stored/Tailscale address). A name collision on the network — e.g. a
    // just-restarted instance whose advertisement hasn't expired — emits an
    // 'error' event that, if unhandled, crashes the whole server. Swallow it.
    this.service.on("error", (err: Error) => {
      console.warn(`[makit] mDNS advertisement failed (non-fatal): ${err.message}`);
    });
  }

  stop() {
    this.service?.stop();
    this.bonjour.destroy();
  }
}
