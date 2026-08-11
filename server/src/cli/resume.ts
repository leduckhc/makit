/**
 * `makit resume <id>` — bring a cold, resumable session back to a live agent
 * (SPEC-46 T14).
 *
 * A thin client of `session.attach` (D1): the same command the app's re-attach
 * path uses. The server re-hydrates the session and re-attaches it to a fresh
 * agent process; the CLI just names which one.
 */
import { withClient } from "./connect.js";
import { EXIT_USAGE } from "./exit-codes.js";

export interface ResumeArgs {
  host: string;
  port: number;
  sessionId?: string;
}

export function parseResumeArgs(argv: string[]): ResumeArgs {
  const a: ResumeArgs = { host: "127.0.0.1", port: 7777 };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i]!;
    if (t === "--host") a.host = String(argv[++i]);
    else if (t === "--port") a.port = Number(argv[++i]);
    else if (!t.startsWith("-") && a.sessionId === undefined) a.sessionId = t;
  }
  return a;
}

function failUsage(message: string): never {
  console.error(`[makit] ${message}`);
  return process.exit(EXIT_USAGE);
}

export async function runResume(argv: string[]): Promise<void> {
  const args = parseResumeArgs(argv);
  if (!args.sessionId) return failUsage("usage: makit resume <id>");

  await withClient(args, async (client) => {
    await client.cmd("session.attach", { sessionId: args.sessionId });
    console.log(`[makit] resumed ${args.sessionId}`);
  });
}
