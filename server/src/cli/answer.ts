/**
 * `makit answer <id> TEXT` — fill a session's pending elicitation (an `input`
 * prompt) with TEXT, from the terminal (SPEC-46 U3).
 *
 * A thin `srv.response` sender over the shared client (see `respond.ts`): the
 * only authorization is the server-side D13 check, never duplicated here. With
 * no pending prompt the verb exits non-zero rather than hanging.
 */
import { respondToPrompt } from "./respond.js";
import { EXIT_USAGE } from "./exit-codes.js";

export interface AnswerArgs {
  host: string;
  port: number;
  sessionId?: string;
  text?: string;
}

export function parseAnswerArgs(argv: string[]): AnswerArgs {
  const a: AnswerArgs = { host: "127.0.0.1", port: 7777 };
  const positionals: string[] = [];
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i]!;
    if (t === "--host") a.host = String(argv[++i]);
    else if (t === "--port") a.port = Number(argv[++i]);
    else if (!t.startsWith("-")) positionals.push(t);
  }
  a.sessionId = positionals[0];
  // Join the rest so an unquoted multi-word answer still arrives intact.
  if (positionals.length > 1) a.text = positionals.slice(1).join(" ");
  return a;
}

export async function runAnswer(argv: string[]): Promise<void> {
  const args = parseAnswerArgs(argv);
  if (!args.sessionId || args.text === undefined) {
    console.error("[makit] usage: makit answer <id> TEXT");
    return process.exit(EXIT_USAGE);
  }
  const text = args.text;
  await respondToPrompt(
    { host: args.host, port: args.port, sessionId: args.sessionId },
    {
      // A multi-question `askUserQuestion` needs indices, not a string: it is
      // answered from the app or `makit attach`, not here.
      kinds: ["input"],
      instead: "approve <id> [--deny]",
      build: () => ({ value: text }),
    },
  );
}
