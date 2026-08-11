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
import { parseFlags, str, int } from "./flags.js";

export interface AnswerArgs {
  host: string;
  port: number;
  sessionId?: string;
  text?: string;
}

export function parseAnswerArgs(argv: string[]): AnswerArgs {
  const p = parseFlags(argv, {
    host: { type: "string", def: "127.0.0.1" },
    port: { type: "int", def: 7777 },
  });
  return {
    host: str(p, "host")!,
    port: int(p, "port")!,
    sessionId: p.positionals[0],
    // Joined so an unquoted multi-word answer still arrives intact.
    text: p.positionals.length > 1 ? p.positionals.slice(1).join(" ") : undefined,
  };
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
