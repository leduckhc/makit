/**
 * `makit approve <id> [--deny]` — answer a session's pending tool-permission
 * prompt (a `confirmAction`) from the terminal (SPEC-46 U3).
 *
 * `--deny` answers `approved: false`. Denial is always an explicit user act:
 * with no pending prompt the verb exits non-zero, it never silently picks the
 * safe answer. A thin `srv.response` sender over the shared client — the only
 * authorization is the server-side D13 check, never duplicated here.
 */
import { respondToPrompt } from "./respond.js";
import { EXIT_USAGE } from "./exit-codes.js";

export interface ApproveArgs {
  host: string;
  port: number;
  sessionId?: string;
  deny: boolean;
}

export function parseApproveArgs(argv: string[]): ApproveArgs {
  const a: ApproveArgs = { host: "127.0.0.1", port: 7777, deny: false };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i]!;
    if (t === "--host") a.host = String(argv[++i]);
    else if (t === "--port") a.port = Number(argv[++i]);
    else if (t === "--deny") a.deny = true;
    else if (!t.startsWith("-") && a.sessionId === undefined) a.sessionId = t;
  }
  return a;
}

export async function runApprove(argv: string[]): Promise<void> {
  const args = parseApproveArgs(argv);
  if (!args.sessionId) {
    console.error("[makit] usage: makit approve <id> [--deny]");
    return process.exit(EXIT_USAGE);
  }
  await respondToPrompt(
    { host: args.host, port: args.port, sessionId: args.sessionId },
    {
      kinds: ["confirmAction"],
      instead: "answer <id> TEXT",
      build: () => ({ approved: !args.deny }),
    },
  );
}
