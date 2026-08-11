/**
 * Build the makit://pair?... URL embedded in the QR.
 *
 * Format:
 *   makit://pair?host=<host>&port=<port>&fp=<sha256-hex>&t=<pairToken>
 *                [&n=<name>][&id=<profileId>]
 *
 * `host` is the best-guess LAN address — first non-internal IPv4. The phone
 * uses mDNS to corroborate, and the cert fingerprint pin defends against
 * accidental connection to the wrong host.
 *
 * `n` (display name) and `id` (stable profile id) are OPTIONAL additions
 * (SPEC-50 D12) that let the phone label each paired server instead of showing
 * a bare IP. There is NO protocol version bump: per-profile pairing already
 * works because the QR carries host/port/fp/t. When both are absent the URL is
 * byte-identical to the pre-D12 output, so already-paired phones and older app
 * builds keep parsing. Absent → the phone falls back to `host:port`.
 */

/**
 * Cap on the profile display name, in Unicode code points.
 *
 * The pair URL is rendered into a QR code, whose capacity is finite: a runaway
 * name (e.g. a pasted 5000-char string) would push the QR past a scannable
 * density. A display label is a short human word ("Work", "feat-profiles"), so
 * 64 code points is generous headroom while keeping the QR small and reliably
 * scannable. Truncation is on code-point boundaries so a multi-unit emoji is
 * never split into a lone surrogate.
 */
export const MAX_PROFILE_NAME_CODE_POINTS = 64;

export interface PairUrlOpts {
  host: string;
  port: number;
  fingerprint: string;
  token: string;
  /** Optional human label for the profile (SPEC-50 D12). */
  name?: string;
  /** Optional stable profile id (SPEC-50 D12). */
  id?: string;
}

export function buildPairUrl(opts: PairUrlOpts): string {
  const u = new URL("makit://pair");
  u.searchParams.set("host", opts.host);
  u.searchParams.set("port", String(opts.port));
  u.searchParams.set("fp", opts.fingerprint);
  u.searchParams.set("t", opts.token);
  // Optional D12 params: only emitted when a non-empty value is supplied, so an
  // absent/empty value keeps the URL byte-identical to the pre-D12 output.
  if (opts.name) {
    u.searchParams.set("n", capName(opts.name));
  }
  if (opts.id) {
    u.searchParams.set("id", opts.id);
  }
  return u.toString();
}

/** Truncate `name` to the cap on code-point boundaries (never splits surrogates). */
function capName(name: string): string {
  const codePoints = [...name];
  if (codePoints.length <= MAX_PROFILE_NAME_CODE_POINTS) return name;
  return codePoints.slice(0, MAX_PROFILE_NAME_CODE_POINTS).join("");
}
