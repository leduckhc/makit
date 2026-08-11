/**
 * `makit resume <id>` — bring a cold, resumable session back to a live agent
 * (SPEC-46 T14).
 *
 * A thin client of `session.attach` (D1): the same command the app's re-attach
 * path uses. The server re-hydrates the session and re-attaches it to a fresh
 * agent process; the CLI just names which one.
 */
import { withClient } from "./connect.js";
import { parseFlags, str, int , failUsage } from "./flags.js";

export interface ResumeArgs {
  host: string;
  port: number;
  sessionId?: string;
}

export function parseResumeArgs(argv: string[]): ResumeArgs {
  const p = parseFlags(argv, {
    host: { type: "string", def: "127.0.0.1" },
    port: { type: "int", def: 7777 },
  });
  return { host: str(p, "host")!, port: int(p, "port")!, sessionId: p.positionals[0] };
}

export async function runResume(argv: string[]): Promise<void> {
  const args = parseResumeArgs(argv);
  if (!args.sessionId) return failUsage("usage: makit resume <id>");

  await withClient(args, async (client) => {
    await client.cmd("session.attach", { sessionId: args.sessionId });
    console.log(`[makit] resumed ${args.sessionId}`);
  });
}
