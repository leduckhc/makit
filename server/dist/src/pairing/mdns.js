/**
 * mDNS advertisement of `_pino._tcp.local` so phones on the same Wi-Fi can
 * auto-discover the server. TXT carries the cert fingerprint and protocol
 * version so the app can corroborate the QR or skip QR entirely on trusted
 * networks.
 */
import { Bonjour } from "bonjour-service";
export class MdnsAd {
    bonjour = new Bonjour();
    service;
    start(opts) {
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
//# sourceMappingURL=mdns.js.map