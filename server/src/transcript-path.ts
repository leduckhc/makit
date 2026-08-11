/**
 * transcript-path — resolve a session's on-disk transcript path.
 *
 * Agent-agnostic dispatcher (SPEC-52 D3). It lives OUTSIDE `pi-sessions.ts` on
 * purpose: two of its three branches are not pi-specific, so P2's codex resolver
 * (`~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<threadId>.jsonl`) becomes an
 * additive branch here rather than forcing a move out of a pi-named module.
 *
 * Boundary rule (docs/ENGINEERING.md, mirrored from pi-sessions.ts): the pi
 * branch reads an untrusted directory on disk. It MUST NEVER throw — a missing
 * dir, an unreadable dir, or a stray entry all yield `undefined`.
 */

import { readdirSync } from "node:fs";
import { join } from "node:path";
import { piSessionsDir, realAgentDir } from "./pi-sessions.js";

/** Everything the resolver needs from a session, decoupled from `Session`. */
export interface TranscriptQuery {
  /** The session's agent id (`pi`, `codex`, …). Only `pi` derives a path in P1. */
  agent: string;
  /** Native agent session/thread id; absent for a draft. */
  agentSessionId?: string;
  /** On-disk transcript for a session attached from disk (authoritative). */
  resumeSessionPath?: string;
  /** The cwd pi actually ran in — the WORKTREE, usually (see manager wiring). */
  cwd?: string;
}

const PI_AGENT = "pi";

/**
 * Resolve the transcript path, or `undefined` (SPEC-52 D3). Order:
 *   (a) `resumeSessionPath` verbatim — authoritative for disk-attached sessions;
 *   (b) else, for pi ONLY, the entry in `piSessionsDir(cwd)` whose basename ends
 *       `_<agentSessionId>.jsonl` — an EXACT suffix, never a prefix, because pi
 *       session ids are UUIDv7 and two can share their first 8 chars (D15);
 *   (c) else `undefined`.
 */
export function resolveTranscriptPath(q: TranscriptQuery, agentDir: string = realAgentDir()): string | undefined {
  if (q.resumeSessionPath) return q.resumeSessionPath;

  if (q.agent !== PI_AGENT || !q.agentSessionId || !q.cwd) return undefined;

  const dir = piSessionsDir(q.cwd, agentDir);
  // Full `_<id>.jsonl` suffix: the leading `_` and full 36-char id together rule
  // out a same-prefix sibling (D15); listing the entry also proves it exists.
  const suffix = `_${q.agentSessionId}.jsonl`;
  try {
    const match = readdirSync(dir).find((entry) => entry.endsWith(suffix));
    return match ? join(dir, match) : undefined;
  } catch {
    // Missing / unreadable dir → no path. Never throw (boundary rule).
    return undefined;
  }
}
