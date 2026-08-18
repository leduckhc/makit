/**
 * `makit ask <id> MSG [--timeout S] [--json]` — ask a session something and print
 * the answer (SPEC-cli-as-client U2).
 *
 * Cross-harness delegation: an agent asks another agent and gets a *string*, not a
 * transcript. `--wait` from the grammar is implicit — the verb exists for it, and
 * an `ask` that returned before the answer would be a slower `send`.
 *
 * The exit code carries the risk, which is D8's warning about exactly this verb:
 * an agent shelling out to it "would hang forever on an approval it cannot see".
 * So a blocked turn exits `10`/`11` and a failed one `20`, each printing **no**
 * answer — a partial reply presented as the answer is worse than no reply, because
 * the caller cannot tell it was cut off.
 */
import { withClient } from "./connect.js";
import { EXIT_USAGE } from "./exit-codes.js";
import { awaitOutcome, codeForStatus } from "./wait.js";
import type { MakitClient } from "./client.js";
import type { SessionEvent } from "../protocol.js";
import { parseFlags, str, int, bool } from "./flags.js";

export interface AskArgs {
  host: string;
  port: number;
  sessionId?: string;
  message?: string;
  timeoutMs?: number;
  json: boolean;
}

export function parseAskArgs(argv: string[]): AskArgs {
  const p = parseFlags(argv, {
    host: { type: "string", def: "127.0.0.1" },
    port: { type: "int", def: 7777 },
    message: { type: "string", alias: "-m" },
    json: { type: "bool" },
    timeout: { type: "int" },
  });
  const secs = int(p, "timeout");
  return {
    host: str(p, "host")!,
    port: int(p, "port")!,
    // `makit ask <id> "the question"` — the spelling an agent reaches for first,
    // with `-m` as the explicit alternative.
    sessionId: p.positionals[0],
    message: str(p, "message") ?? p.positionals[1],
    json: bool(p, "json"),
    timeoutMs: secs !== undefined && secs > 0 ? secs * 1000 : undefined,
  };
}

export async function runAsk(argv: string[]): Promise<void> {
  const args = parseAskArgs(argv);
  if (!args.sessionId || args.message === undefined) {
    console.error("[makit] usage: makit ask <id> MSG [--timeout S] [--json]");
    return process.exit(EXIT_USAGE);
  }
  const sessionId = args.sessionId;

  await withClient(args, (client) => askOnce(client, sessionId, args));
}

/** The check + send + wait body. */
async function askOnce(client: MakitClient, sessionId: string, args: AskArgs): Promise<void> {
  // A session that is already blocked or gone cannot answer: the message would sit
  // in the queue, no turn would start, and with no default timeout `ask` would hang
  // — the exact failure D8 names for this verb. `wait` checks the snapshot before
  // waiting; so must this.
  const current = (await client.awaitSnapshot()).sessions.find((s) => s.id === sessionId);
  if (!current) {
    console.error(`[makit] no such session: ${sessionId}`);
    return process.exit(1);
  }
  const already = codeForStatus(current.status);
  if (already !== undefined && already !== 0) {
    console.error(`[makit] session is ${current.status} — it cannot answer right now`);
    return process.exit(already);
  }

  // Only the FINAL message is the answer: an agent narrates on the way there, and
  // an interim thought printed as the reply would be a wrong answer.
  let last: SessionEvent | undefined;
  const waiting = awaitOutcome(client, sessionId, {
    forWhat: "any",
    timeoutMs: args.timeoutMs,
    initialStatus: current.status,
    onEvent: (ev) => {
      if (ev.kind === "agent.message") last = ev;
    },
  });
  await client.cmd("send.message", { sessionId, text: args.message });
  const outcome = await waiting;

  if (outcome.code !== 0) {
    // Blocked, failed, or timed out: say why on stderr and print no answer.
    if (outcome.message) console.error(`[makit] ${outcome.message}`);
    return process.exit(outcome.code);
  }
  if (!last) {
    console.error("[makit] the turn completed with no answer");
    return process.exit(1);
  }
  console.log(args.json ? JSON.stringify(last) : String(last.payload.text ?? ""));
}
