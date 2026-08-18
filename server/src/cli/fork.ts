/**
 * `makit fork <id> [--agent A] [--worktree]` — SPEC-cli-as-client U4, the completion of
 * SPEC-session-lifecycle-resume-list-delete's PENDING `session.fork`.
 *
 * This is the **adapter-native** fork: a high-fidelity branch of the *same*
 * conversation (codex `thread/fork`), not `makit handoff`. A handoff carries a
 * written manifest across harnesses; a fork continues the identical thread with
 * full context (D6). The server does the fork on the source's live adapter and
 * spawns the child that resumes the forked thread; this CLI is the thin client.
 *
 * `makit fork` is `handoff`'s near-sibling in shape (D15 inverse): the child
 * inherits the parent's `worktreePath` and branch, because the forked thread's
 * context refers to files as they are now, and a fresh tree off the default
 * branch would strand the uncommitted work it is reasoning about. `--worktree`
 * opts into a fresh tree instead.
 *
 * Unlike `handoff`, the source is named on the argv (there is no manifest and no
 * first message to write): `makit fork <id>`.
 */
import { withClient } from "./connect.js";
import type { SessionDTO } from "../protocol.js";
import { parseFlags, str, int, bool, failUsage } from "./flags.js";

export interface ForkArgs {
  host: string;
  port: number;
  sessionId?: string;
  agent?: string;
  freshWorktree: boolean;
  branch?: string;
  base?: string;
  json: boolean;
}

export function parseForkArgs(argv: string[]): ForkArgs {
  const p = parseFlags(argv, {
    host: { type: "string", def: "127.0.0.1" },
    port: { type: "int", def: 7777 },
    agent: { type: "string" },
    worktree: { type: "bool" },
    branch: { type: "string" },
    base: { type: "string" },
    json: { type: "bool" },
  });
  return {
    host: str(p, "host")!,
    port: int(p, "port")!,
    sessionId: p.positionals[0],
    agent: str(p, "agent"),
    freshWorktree: bool(p, "worktree"),
    branch: str(p, "branch"),
    base: str(p, "base"),
    json: bool(p, "json"),
  };
}


export async function runFork(argv: string[]): Promise<void> {
  const args = parseForkArgs(argv);
  if (!args.sessionId) return failUsage("usage: makit fork <id> [--agent A] [--worktree]");

  await withClient(args, async (client) => {
    const source = (await client.awaitSnapshot()).sessions.find(
      (s: SessionDTO) => s.id === args.sessionId,
    );

    // A source we cannot read is refused outright. The server takes
    // `worktreePath` at face value rather than re-deriving it from the source,
    // so proceeding with `undefined` would fork a session that *is* resolvable
    // server-side (an closed one, say) into a child with no tree at all —
    // silently the opposite of the rule below.
    if (!source) {
      return failUsage(`cannot find session ${args.sessionId} in the snapshot — is it closed?`);
    }

    // D15 inverse: inherit the source's tree, or take a fresh one on request.
    // Resolved from the snapshot the app itself reads, so the terminal cannot
    // drift from the phone. The server still verifies the path belongs to the
    // project (spawnPendingSession) and refuses an unknown source outright.
    let worktreePath = source.worktreePath;
    let branch = source.branch;
    if (args.freshWorktree) {
      const projectId = source.projectId;
      if (!projectId) {
        return failUsage(`cannot resolve the project of session ${args.sessionId} — is it still live?`);
      }
      const created = await client.cmd("worktree.create", {
        projectId,
        branchName: args.branch,
        baseBranch: args.base,
      });
      worktreePath = String(created.path);
      branch = typeof created.branch === "string" ? created.branch : undefined;
    }

    const forked = await client.cmd("session.fork", {
      sessionId: args.sessionId,
      agent: args.agent,
      worktreePath,
      branch,
    });
    const sessionId = String(forked.sessionId);

    if (args.json) {
      console.log(JSON.stringify({ sessionId }));
      return;
    }
    const to = args.agent ? ` to ${args.agent}` : "";
    const where = branch ? ` on ${branch}` : "";
    console.log(`[makit] forked${to} — session ${sessionId}${where}`);
  });
}
