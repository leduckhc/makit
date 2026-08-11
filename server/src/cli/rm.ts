/**
 * `makit rm <id> [--kill]` — end a session from the terminal (SPEC-46 T14).
 *
 * The default is deliberately the **recoverable** one: `rm` closes (a soft
 * hide — the session stays resumable and `makit ls --closed` still shows it),
 * and only `--kill` tears the agent down for good. Defaulting to the destructive
 * verb would be the wrong way round, so close is the default and kill opts in.
 */
import { withClient } from "./connect.js";
import { parseFlags, str, int, bool , failUsage } from "./flags.js";

export interface RmArgs {
  host: string;
  port: number;
  sessionId?: string;
  kill: boolean;
}

export function parseRmArgs(argv: string[]): RmArgs {
  const p = parseFlags(argv, {
    host: { type: "string", def: "127.0.0.1" },
    port: { type: "int", def: 7777 },
    kill: { type: "bool" },
  });
  return {
    host: str(p, "host")!,
    port: int(p, "port")!,
    sessionId: p.positionals[0],
    kill: bool(p, "kill"),
  };
}

export async function runRm(argv: string[]): Promise<void> {
  const args = parseRmArgs(argv);
  if (!args.sessionId) return failUsage("usage: makit rm <id> [--kill]");

  await withClient(args, async (client) => {
    if (args.kill) {
      await client.cmd("session.kill", { sessionId: args.sessionId });
      console.log(`[makit] killed ${args.sessionId}`);
    } else {
      await client.cmd("session.close", { sessionId: args.sessionId });
      console.log(`[makit] closed ${args.sessionId}`);
    }
  });
}
