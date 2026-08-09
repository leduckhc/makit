/**
 * docker.ts — the one place that knows anything about docker (SPEC-42 D13).
 *
 * A container that publishes a port is held on the host by docker's own proxy
 * process (`com.docker.backend` on Docker Desktop, `docker-proxy`/`dockerd` on
 * Linux), so `lsof` attributes the listener to docker and the row reads as
 * unowned system noise. `docker ps` is the only source that can say which
 * container is behind it.
 *
 * Two rules keep this cheap and honest:
 *  - **The exit code is checked.** `run()` never rejects: a missing binary
 *    resolves with `{code:127, stdout:""}`. Trusting `stdout` alone would read
 *    "docker is not installed" as "there are no containers" and silently
 *    un-annotate every container port — the trap this file exists to avoid.
 *    A failed read yields `ok:false` and NO annotations, i.e. "not known".
 *  - **The result is TTL-cached** (containers do not appear and vanish inside a
 *    few scan ticks) and a machine with no docker BINARY is never probed again.
 *
 * `docker` is an ownership annotation, never a `reach` (D13): the overlay in
 * `service.ts` leaves `reach` reporting the real bind address.
 */

import type { PortDockerDTO } from "../protocol.js";
import type { Exec } from "./scan.js";

/**
 * How long one `docker ps` answer is reused. 10 s ≈ 2–3 scan ticks: long enough
 * that the steady state pays for docker once per handful of scans, short enough
 * that a container the user just started shows up while they are still looking.
 */
export const DOCKER_TTL_MS = 10_000;

/**
 * `docker ps` with a tab-separated format: name, publish map, compose files.
 * Tab-separated (not the default table) so a container name with spaces cannot
 * shift the columns.
 */
const DOCKER_PS_ARGS = [
  "ps",
  "--format",
  '{{.Names}}\t{{.Ports}}\t{{.Label "com.docker.compose.project.config_files"}}',
] as const;

/** Result of one docker read. `byHostPort` is empty whenever `ok` is false. */
export interface DockerRead {
  /**
   * True only when `docker ps` actually ran and exited 0. False means "not
   * known" — never "no containers", which is why the caller must not clear
   * annotations on a false.
   */
  ok: boolean;
  /** Host port → the container publishing it. */
  byHostPort: Map<number, PortDockerDTO>;
}

/** A TTL-cached docker reader (see {@link createDockerReader}). */
export type DockerReader = (timeoutMs?: number) => Promise<DockerRead>;

/**
 * One publish entry: `0.0.0.0:5432->5432/tcp`, `127.0.0.1:8080->80/tcp`,
 * `:::5432->5432/tcp`, `[::]:5432->5432/tcp`. The HOST port (before `->`) is
 * the one `lsof` sees, so it is the only one captured. An entry with no host
 * part (`5432/tcp`, an unpublished port) does not match at all, and `/udp`
 * entries are excluded — SPEC-41 scans TCP only.
 */
const PUBLISH_TCP = /(?:^|[\s,])(?:\[[^\]]*\]|[^\s,]*):(\d+)->\d+\/tcp/g;

/**
 * Parse `docker ps` stdout into a host-port → container map. Pure and
 * total: a row without tabs, without a name, or with an unparsable publish map
 * is skipped, never thrown — `docker ps` output varies by version and one odd
 * row must not lose the containers around it (the `lsof` parser's rule).
 */
export function parseDockerPs(stdout: string): Map<number, PortDockerDTO> {
  const byHostPort = new Map<number, PortDockerDTO>();
  for (const line of stdout.split("\n")) {
    if (line.length === 0) continue;
    const [name, publishes, labels] = line.split("\t");
    if (name === undefined || publishes === undefined) continue;
    const container = name.trim();
    if (container.length === 0) continue;

    // The compose label is a comma-separated LIST when a project was started
    // with several files; the first is the one the user thinks of as "the
    // compose file", and an empty label means a plain `docker run`.
    const compose = (labels ?? "").split(",")[0]?.trim();

    for (const match of publishes.matchAll(PUBLISH_TCP)) {
      const hostPort = Number(match[1]);
      if (!Number.isInteger(hostPort) || hostPort <= 0) continue;
      // First writer wins: a container publishing the same host port over IPv4
      // and IPv6 (`0.0.0.0:5432->…, :::5432->…`) is ONE container.
      if (byHostPort.has(hostPort)) continue;
      byHostPort.set(
        hostPort,
        compose !== undefined && compose.length > 0 ? { container, compose } : { container },
      );
    }
  }
  return byHostPort;
}

/** Empty read used for every failure path — "not known", not "none". */
const UNKNOWN: DockerRead = { ok: false, byHostPort: new Map() };

/**
 * Whether a listener's command is docker's host-side proxy, i.e. the only
 * process whose ports a container may claim.
 *
 * Matched on the executable NAME, not a substring of the whole argv: a
 * `node build-docker-image.js` listening on 5432 must not be relabelled as a
 * container, and neither must a native postgres that happens to share a port
 * number with one.
 */
export function isDockerBackend(command: string): boolean {
  const argv0 = command.trim().split(/\s+/)[0] ?? "";
  const exe = argv0.slice(argv0.lastIndexOf("/") + 1);
  return exe === "com.docker.backend" || exe === "docker-proxy" || exe === "dockerd";
}

/**
 * Build a TTL-cached reader over `exec`. Stateful by design (the cache), so it
 * is created once per service and injected — the same seam as `exec` itself.
 *
 * A `code:127` whose stderr carries `ENOENT` means the binary is not there and
 * never will be within this process's life, so it is remembered and never
 * probed again. Every other failure (a stopped daemon, a timeout — which
 * `run()` also reports as 127) keeps the TTL and is retried, because those come
 * back.
 */
export function createDockerReader(exec: Exec, now: () => number): DockerReader {
  let cached: DockerRead | undefined;
  let cachedAt = 0;
  let binaryMissing = false;

  return async (timeoutMs?: number): Promise<DockerRead> => {
    if (binaryMissing) return UNKNOWN;
    if (cached !== undefined && now() - cachedAt < DOCKER_TTL_MS) return cached;

    let result: DockerRead;
    try {
      const { code, stdout, stderr } = await exec("docker", [...DOCKER_PS_ARGS], undefined, timeoutMs);
      if (code !== 0) {
        if (/ENOENT/.test(stderr)) binaryMissing = true;
        result = UNKNOWN;
      } else {
        result = { ok: true, byHostPort: parseDockerPs(stdout) };
      }
    } catch {
      // `exec` is injected, so a caller could hand us something that rejects;
      // a docker read must never be able to fail a scan.
      result = UNKNOWN;
    }

    cached = result;
    cachedAt = now();
    return result;
  };
}
