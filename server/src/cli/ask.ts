/**
 * `makit ask <id> MSG [--timeout S] [--json]` — ask a session something and print
 * the answer (SPEC-46 U2).
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
import { connectCli } from "./connect.js";
import { EXIT_USAGE } from "./exit-codes.js";
import { awaitOutcome, codeForStatus } from "./wait.js";
import type { SessionEvent } from "../protocol.js";

export interface AskArgs {
  host: string;
  port: number;
  sessionId?: string;
  message?: string;
  timeoutMs?: number;
  json: boolean;
}

export function parseAskArgs(argv: string[]): AskArgs {
  const a: AskArgs = { host: "127.0.0.1", port: 7777, json: false };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i]!;
    if (t === "--host") a.host = String(argv[++i]);
    else if (t === "--port") a.port = Number(argv[++i]);
    else if (t === "-m" || t === "--message") a.message = String(argv[++i]);
    else if (t === "--json") a.json = true;
    else if (t === "--timeout") {
      const s = Number(argv[++i]);
      if (Number.isFinite(s) && s > 0) a.timeoutMs = s * 1000;
    } else if (!t.startsWith("-")) {
      // `makit ask <id> "the question"` — the spelling an agent reaches for first.
      if (a.sessionId === undefined) a.sessionId = t;
      else if (a.message === undefined) a.message = t;
    }
  }
  return a;
}

export async function runAsk(argv: string[]): Promise<void> {
  const args = parseAskArgs(argv);
  if (!args.sessionId || args.message === undefined) {
    console.error("[makit] usage: makit ask <id> MSG [--timeout S] [--json]");
    return process.exit(EXIT_USAGE);
  }
  const sessionId = args.sessionId;

  const client = await connectCli(args);

  // A session that is already blocked or gone cannot answer: the message would sit
  // in the queue, no turn would start, and with no default timeout `ask` would hang
  // — the exact failure D8 names for this verb. `wait` checks the snapshot before
  // waiting; so must this.
  const current = (await client.awaitSnapshot()).sessions.find((s) => s.id === sessionId);
  if (!current) {
    console.error(`[makit] no such session: ${sessionId}`);
    client.close();
    return process.exit(1);
  }
  const already = codeForStatus(current.status);
  if (already !== undefined && already !== 0) {
    console.error(`[makit] session is ${current.status} — it cannot answer right now`);
    client.close();
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
  client.close();

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
