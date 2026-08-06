/**
 * attribute.ts — pure attribution: turn raw listeners + a process table into the
 * `PortDTO[]` the wire carries. No I/O, no clock, no throw.
 *
 * The owner of a port is a WORKTREE, derived by matching a process's working
 * directory (its own, or the nearest ancestor's) against the set of live
 * worktree paths — longest path-segment prefix wins. See the spec's attribution
 * diagram (§"Attribution: how a port gets an owner").
 */

import type { PortDTO, PortHealthDTO, PortReach } from "../protocol.js";
import { childIndex, descendants } from "../metrics/tree.js";
import type { Listener } from "./scan.js";
import type { ProcInfo } from "./proc.js";
import { walkAncestors } from "./ancestors.js";

/**
 * Argv is trimmed to keep one pathological command (a huge `--define` blob, a
 * shell one-liner) from bloating every snapshot. 512 comfortably holds a real
 * `node …/vite --host … --port …` while capping the outlier.
 */
export const MAX_COMMAND_CHARS = 512;

export interface AttributeInput {
  listeners: Listener[];
  procs: Map<number, ProcInfo>;
  /** cwd per pid — covers listeners AND their ancestors (see ancestors.ts). */
  cwds: Map<number, string>;
  /** Absolute worktree paths, from the cached repos snapshot (no git per scan). */
  worktreePaths: string[];
  /** Session id → its agent root pid, supplied by the caller (no session import). */
  sessionRoots: Map<string, number>;
  /** Cached HTTP verdict for an endpoint, or undefined when not probed. */
  health: (address: string, port: number) => PortHealthDTO | undefined;
  /** The host's discovered tailnet address, or null when Tailscale is absent. */
  tailnetAddress: string | null;
  /** Memoised realpath resolver (macOS /tmp aliasing) — see proc.ts. */
  resolveReal: (path: string) => string;
}

/** Split an absolute path into non-empty segments: `/a/b` → `['a','b']`. */
function segments(path: string): string[] {
  return path.split("/").filter((s) => s.length > 0);
}

/**
 * Tailscale hands every node an address in **100.64.0.0/10** (the CGNAT range),
 * i.e. `100.<64..127>.*`. Matching a bare `100.` would also claim 100.0.0.0/10
 * and 100.128.0.0/9, which are ordinary internet-routable space — labelling such
 * a bind `tailnet` would be the reassuring reading of the more alarming fact,
 * which spec D2 exists to prevent.
 */
const TAILNET_ADDRESS = /^100\.(\d{1,3})\./;
const TAILNET_MIN_SECOND_OCTET = 64;
const TAILNET_MAX_SECOND_OCTET = 127;

/**
 * The tailnet address the server ALREADY discovered at bind time (spec D2), from
 * the bind host — NO `tailscale` subprocess. The secure-by-default bind chooses
 * the host's `100.x` tailnet IP when Tailscale is up, so when `host` is that
 * address it IS the discovered tailnet address; any other bind (loopback, LAN,
 * wildcard, or an explicit `--host`) means no tailnet address was discovered, so
 * nothing is labelled `tailnet`. Pure + synchronous by construction: this must
 * never run a subprocess on the scan path (a hung `tailscale` CLI would block
 * the event loop mid-scan).
 */
export function tailnetAddressFromBindHost(host: string): string | null {
  const match = TAILNET_ADDRESS.exec(host);
  if (match === null) return null;
  const secondOctet = Number(match[1]);
  const inCgnat =
    secondOctet >= TAILNET_MIN_SECOND_OCTET && secondOctet <= TAILNET_MAX_SECOND_OCTET;
  return inCgnat ? host : null;
}

/** True when `prefix` is a whole-segment prefix of `path` (so /a/b ⊄ /a/b-2). */
function isSegmentPrefix(prefix: string[], path: string[]): boolean {
  if (prefix.length > path.length) return false;
  return prefix.every((seg, i) => seg === path[i]);
}

/** The one resolved worktree, longest segment-prefix of `cwd`, or undefined. */
function matchWorktree(
  cwd: string,
  worktrees: Array<{ original: string; segs: string[] }>,
): string | undefined {
  const cwdSegs = segments(cwd);
  let best: string | undefined;
  let bestLen = -1;
  for (const wt of worktrees) {
    if (isSegmentPrefix(wt.segs, cwdSegs) && wt.segs.length > bestLen) {
      best = wt.original;
      bestLen = wt.segs.length;
    }
  }
  return best;
}

/** Loopback address forms `lsof` reports (IPv4 127/8 and IPv6 ::1). */
function isLoopback(address: string): boolean {
  return address === "::1" || address.startsWith("127.");
}

/** Wildcard binds: reachable from every interface, so never `tailnet` (D2). */
function isWildcard(address: string): boolean {
  return address === "*" || address === "0.0.0.0" || address === "::";
}

function reachOf(address: string, tailnetAddress: string | null): PortReach {
  if (isWildcard(address)) return "exposed";
  if (isLoopback(address)) return "loopback";
  if (tailnetAddress !== null && address === tailnetAddress) return "tailnet";
  return "exposed";
}

/**
 * The canonical URL to open, built once here so the two clients cannot disagree.
 * Wildcard/loopback IPv4 collapse to 127.0.0.1; the IPv6 forms are bracketed.
 */
function buildOpenUrl(address: string, port: number): string {
  let host: string;
  if (isWildcard(address) && !address.includes(":")) host = "127.0.0.1"; // * / 0.0.0.0
  else if (address === "::" || address === "::1") host = "[::1]";
  else if (address.startsWith("127.")) host = "127.0.0.1";
  else if (address.includes(":")) host = `[${address}]`; // any other IPv6
  else host = address;
  return `http://${host}:${port}`;
}

/** An HTTP verdict (something answered) is the only thing that yields an openUrl. */
function hasHttpVerdict(health: PortHealthDTO | undefined): boolean {
  return health?.kind === "ok" || health?.kind === "http-error";
}

/**
 * The worktree owning `pid`: try its own cwd, then climb ancestors (bounded,
 * cycle-safe) to the nearest one whose cwd resolves under a worktree. The walk
 * itself lives in ancestors.ts ({@link walkAncestors}) so its bound and cycle
 * guard cannot drift from the one {@link cwdPidSet} uses.
 */
function ownerOf(
  pid: number,
  procs: Map<number, ProcInfo>,
  cwds: Map<number, string>,
  worktrees: Array<{ original: string; segs: string[] }>,
  resolveReal: (path: string) => string,
): string | undefined {
  for (const current of walkAncestors(pid, procs)) {
    const cwd = cwds.get(current);
    if (cwd !== undefined) {
      const match = matchWorktree(resolveReal(cwd), worktrees);
      if (match !== undefined) return match;
    }
  }
  return undefined;
}

/** Map every pid in each session's process subtree back to its session id. */
function buildSessionIndex(
  procs: Map<number, ProcInfo>,
  sessionRoots: Map<string, number>,
): Map<number, string> {
  const pidToSession = new Map<number, string>();
  if (sessionRoots.size === 0) return pidToSession;
  // childIndex/descendants read only pid/ppid; ProcInfo satisfies that subset,
  // so no cast is needed (childIndex's param is widened to accept it).
  const index = childIndex(procs);
  for (const [sessionId, root] of sessionRoots) {
    for (const pid of descendants(index, root)) {
      if (!pidToSession.has(pid)) pidToSession.set(pid, sessionId);
    }
  }
  return pidToSession;
}

export function attribute(input: AttributeInput): PortDTO[] {
  const { listeners, procs, cwds, sessionRoots, health, tailnetAddress, resolveReal } = input;

  // Resolve worktree paths ONCE (aliasing) and precompute their segments.
  const worktrees = input.worktreePaths.map((original) => ({
    original,
    segs: segments(resolveReal(original)),
  }));

  // Build the session pid→id index ONCE for every listener, not per listener.
  const pidToSession = buildSessionIndex(procs, sessionRoots);

  const ports = listeners.map((l): PortDTO => {
    const proc = procs.get(l.pid);
    const dto: PortDTO = {
      key: `${l.pid}:${l.address}:${l.port}`,
      port: l.port,
      address: l.address,
      reach: reachOf(l.address, tailnetAddress),
      pid: l.pid,
      command: (proc?.command ?? "").slice(0, MAX_COMMAND_CHARS),
    };
    if (proc?.startedAt !== undefined) dto.startedAt = proc.startedAt;

    const worktreePath = ownerOf(l.pid, procs, cwds, worktrees, resolveReal);
    if (worktreePath !== undefined) {
      dto.worktreePath = worktreePath;
      // Health is read ONLY once ownership is known (D3: probed only for ports
      // attributed to a worktree). Reading it before deciding ownership would
      // attach a stale verdict — and its openUrl — to a port that has since
      // become unowned, which is exactly the endpoint we must NOT surface.
      const verdict = health(l.address, l.port);
      if (verdict !== undefined) dto.health = verdict;
      if (hasHttpVerdict(verdict)) dto.openUrl = buildOpenUrl(l.address, l.port);
    }

    const sessionId = pidToSession.get(l.pid);
    if (sessionId !== undefined) dto.sessionId = sessionId;

    return dto;
  });

  // Ascending by port, then pid, then address — the wire contract's sort
  // (PortsSnapshotDTO). `address` is the tie-breaker that makes the order TOTAL:
  // a dual-stack process yields two listeners with the same pid and port but
  // different addresses, and without it their order would depend on lsof's print
  // order — a non-deterministic reordering the dedup projection reads as a change.
  ports.sort(
    (a, b) =>
      a.port - b.port ||
      a.pid - b.pid ||
      (a.address < b.address ? -1 : a.address > b.address ? 1 : 0),
  );
  return ports;
}
