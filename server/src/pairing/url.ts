/**
 * Build the makit://pair?... URL embedded in the QR.
 *
 * Format:
 *   makit://pair?host=<host>&port=<port>&fp=<sha256-hex>&t=<pairToken>
 *
 * `host` is the best-guess LAN address — first non-internal IPv4. The phone
 * uses mDNS to corroborate, and the cert fingerprint pin defends against
 * accidental connection to the wrong host.
 */

export interface PairUrlOpts {
  host: string;
  port: number;
  fingerprint: string;
  token: string;
}

export function buildPairUrl(opts: PairUrlOpts): string {
  const u = new URL("makit://pair");
  u.searchParams.set("host", opts.host);
  u.searchParams.set("port", String(opts.port));
  u.searchParams.set("fp", opts.fingerprint);
  u.searchParams.set("t", opts.token);
  return u.toString();
}
