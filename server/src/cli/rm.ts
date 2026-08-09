/**
 * `makit rm <id> [--kill]` — end a session from the terminal (SPEC-46 T14).
 *
 * The default is deliberately the **recoverable** one: `rm` archives (a soft
 * hide — the session stays resumable and `makit ls --archived` still shows it),
 * and only `--kill` tears the agent down for good. Defaulting to the destructive
 * verb would be the wrong way round, so archive is the default and kill opts in.
 */
import { AuthError } from "./client.js";
import { connectCli, failAuth } from "./connect.js";
import { EXIT_USAGE } from "./exit-codes.js";

export interface RmArgs {
  host: string;
  port: number;
  sessionId?: string;
  kill: boolean;
}

export function parseRmArgs(argv: string[]): RmArgs {
  const a: RmArgs = { host: "127.0.0.1", port: 7777, kill: false };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i]!;
    if (t === "--host") a.host = String(argv[++i]);
    else if (t === "--port") a.port = Number(argv[++i]);
    else if (t === "--kill") a.kill = true;
    else if (!t.startsWith("-") && a.sessionId === undefined) a.sessionId = t;
  }
  return a;
}

function failUsage(message: string): never {
  console.error(`[makit] ${message}`);
  return process.exit(EXIT_USAGE);
}

export async function runRm(argv: string[]): Promise<void> {
  const args = parseRmArgs(argv);
  if (!args.sessionId) return failUsage("usage: makit rm <id> [--kill]");

  const client = await connectCli(args);
  try {
    if (args.kill) {
      await client.cmd("session.kill", { sessionId: args.sessionId });
      console.log(`[makit] killed ${args.sessionId}`);
    } else {
      await client.cmd("session.archive", { sessionId: args.sessionId });
      console.log(`[makit] archived ${args.sessionId}`);
    }
  } catch (e) {
    if (e instanceof AuthError) return failAuth(e.message);
    console.error(`[makit] ${(e as Error).message}`);
    process.exit(1);
  } finally {
    client.close();
  }
}
