/**
 * mDNS advertisement of `_pino._tcp.local` so phones on the same Wi-Fi can
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
      name: opts.hostLabel ?? `pino on ${process.env.USER ?? "host"}`,
      type: "pino",
      protocol: "tcp",
      port: opts.port,
      txt: {
        fp: opts.fingerprint,
        v: "1",
      },
    });
  }

  stop() {
    this.service?.stop();
    this.bonjour.destroy();
  }
}
