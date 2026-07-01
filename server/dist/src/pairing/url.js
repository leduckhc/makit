/**
 * Build the pino://pair?... URL embedded in the QR.
 *
 * Format:
 *   pino://pair?host=<host>&port=<port>&fp=<sha256-hex>&t=<pairToken>
 *
 * `host` is the best-guess LAN address — first non-internal IPv4. The phone
 * uses mDNS to corroborate, and the cert fingerprint pin defends against
 * accidental connection to the wrong host.
 */
export function buildPairUrl(opts) {
    const u = new URL("pino://pair");
    u.searchParams.set("host", opts.host);
    u.searchParams.set("port", String(opts.port));
    u.searchParams.set("fp", opts.fingerprint);
    u.searchParams.set("t", opts.token);
    return u.toString();
}
//# sourceMappingURL=url.js.map