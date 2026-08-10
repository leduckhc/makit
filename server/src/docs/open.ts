/**
 * makit — SPEC-46 D8 rev 2: open a document on the machine that holds it.
 *
 * When the viewer is already on the server's host there is nothing to serve: the
 * OS opener hands the file to the real browser with perfect fidelity, no HTTP, no
 * grant, no TTL, no Tailscale and no listener. Publishing (D9/D10/D15) exists for
 * the case this one cannot cover — a *different* device.
 *
 * Two constraints make this safe to expose at all:
 *   1. The caller must be a **local** client. That gate lives in the command
 *      layer, which is the only place that knows the connection.
 *   2. The path goes through {@link resolveDocPath}, the same boundary the WSS
 *      read and the static route share, so "open" can never reach a dotfile,
 *      an excluded directory, a non-document extension or outside the worktree.
 *
 * The path is passed as an argv element and never through a shell, so a filename
 * containing spaces, quotes or `;` is inert.
 */

import { execFile } from "node:child_process";

import { resolveDocPath, type DocPathResult } from "./resolve.js";

/** `execFile`-shaped, injected so a test never launches a browser. */
export type Spawn = (cmd: string, args: string[], cb: (err: Error | null) => void) => void;

export interface OpenDocDeps {
  /** Injected for tests; defaults to `process.platform`. */
  platform?: NodeJS.Platform;
  /** Injected for tests; defaults to {@link execFile}. */
  spawn?: Spawn;
  /** Injected for tests; defaults to {@link resolveDocPath}. */
  resolveDoc?: (worktreeRoot: string, relPath: string) => DocPathResult;
}

export type OpenResult = { ok: true; absPath: string } | { ok: false; reason: string };

/** The OS opener for `platform`, or undefined when we have no idea. */
function openerFor(platform: NodeJS.Platform): { cmd: string; args: string[] } | undefined {
  switch (platform) {
    case "darwin":
      return { cmd: "/usr/bin/open", args: [] };
    case "win32":
      // `start` is a cmd builtin; the empty "" is its title argument, without
      // which a quoted path is treated AS the title and nothing opens.
      return { cmd: "cmd", args: ["/c", "start", ""] };
    default:
      return { cmd: "xdg-open", args: [] };
  }
}

/**
 * Open one document with the host's default application. Resolves once the
 * opener has been launched — not once the browser has painted, which is not
 * observable and not worth waiting for.
 */
export async function openDocOnHost(
  worktreePath: string,
  relPath: string,
  deps: OpenDocDeps = {},
): Promise<OpenResult> {
  const resolveDoc = deps.resolveDoc ?? resolveDocPath;
  const platform = deps.platform ?? process.platform;
  const spawn = deps.spawn ?? ((cmd, args, cb) => void execFile(cmd, args, (err) => cb(err)));

  const resolved = resolveDoc(worktreePath, relPath);
  if (!resolved.ok) return { ok: false, reason: `cannot open ${relPath}: ${resolved.reason}` };

  const opener = openerFor(platform);
  if (opener === undefined) {
    return { ok: false, reason: `no known opener for platform ${platform}` };
  }

  return new Promise<OpenResult>((resolve) => {
    spawn(opener.cmd, [...opener.args, resolved.absPath], (err) => {
      if (err !== null) {
        resolve({ ok: false, reason: `opener failed: ${err.message}` });
        return;
      }
      resolve({ ok: true, absPath: resolved.absPath });
    });
  });
}
