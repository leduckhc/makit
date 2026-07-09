/**
 * `makit sessions`
 *
 * Lists running sessions via the daemon's control socket (SPEC-02).
 * Shows: id, title, status, project, last activity.
 */

import { requireDaemon } from "./require-daemon.js";
import { controlSocketPath } from "../daemon/paths.js";
import type { SessionsListData } from "../daemon/protocol.js";

function fmtAge(ts: number): string {
  if (!ts) return "never";
  const s = Math.floor((Date.now() - ts) / 1000);
  if (s < 60) return `${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ago`;
  return `${Math.floor(m / 60)}h ago`;
}

export async function runSessions(argv: string[]): Promise<void> {
  void argv;
  const client = await requireDaemon(controlSocketPath());
  try {
    const res = await client.request<SessionsListData>("sessions.list");
    if (!res.ok) {
      console.error(`[makit] sessions.list failed: ${res.error}`);
      process.exit(1);
    }
    const { sessions } = res.data!;
    if (sessions.length === 0) {
      console.log("no sessions");
      return;
    }
    for (const s of sessions) {
      const title = s.title || "(untitled)";
      console.log(`${s.id}  [${s.status}]  ${title}  project:${s.projectId}  last:${fmtAge(s.lastActivityAt)}`);
    }
  } finally {
    client.close();
  }
}
