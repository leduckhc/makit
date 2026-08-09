/**
 * `makit wait <id> [--for idle|approval|input|any] [--timeout S]` — block until
 * something happens to a session, and say which thing in the exit code (SPEC-46
 * T16, D8).
 *
 * Without distinct codes a git hook or a CI job cannot tell "the agent finished"
 * from "the agent is blocked on you", and an agent shelling out to `makit …
 * --wait` would hang forever on an approval it cannot see.
 *
 * Two facts about makit shape the implementation, both recorded in D8:
 *
 *   - **The wait is edge-triggered.** `send.message` acks *before* the draft is
 *     promoted, so a composed `new + send + wait` would see the pre-existing
 *     `idle` and exit `0` having waited for nothing. So a completed turn means a
 *     `running` → non-running **transition**, the same boundary the app's own
 *     notification policy uses.
 *   - **Nothing ever emits `status: "error"`.** Adapters emit a `session.error`
 *     *event* and then settle `idle`, so `20` keys off the event; keying off the
 *     status would report a failed turn as a clean success.
 *
 * A session that is *already* blocked or exited when `wait` starts reports that
 * immediately: no edge is required, because it is already waiting on the human,
 * and pretending otherwise would hang a script on a question it cannot see.
 */
import { connectCli } from "./connect.js";
import { EXIT_USAGE } from "./exit-codes.js";
import type { MakitClient } from "./client.js";
import type { SessionEvent } from "../protocol.js";

/** Blocked on a tool permission (D8). */
export const EXIT_APPROVAL = 10;
/** Blocked on an elicitation (D8). */
export const EXIT_INPUT = 11;
/** A terminal `session.error` event (D8). */
export const EXIT_ERROR = 20;
/** The agent process exited (D8). */
export const EXIT_EXITED = 21;
/**
 * `--timeout` elapsed. D8 reserves no code for it, so this is `timeout(1)`'s
 * conventional `124` — deliberately outside D8's set so a script can never
 * confuse "gave up waiting" with any real outcome.
 */
export const EXIT_TIMEOUT = 124;

export type WaitFor = "idle" | "approval" | "input" | "any";

/** Frame id for our `sub`, so its ack (end of replay) is recognisable. */
const SUB_ID = "wait-sub";

export interface WaitArgs {
  host: string;
  port: number;
  sessionId?: string;
  forWhat: WaitFor;
  timeoutMs?: number;
}

export function parseWaitArgs(argv: string[]): WaitArgs {
  const a: WaitArgs = { host: "127.0.0.1", port: 7777, forWhat: "any" };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i]!;
    if (t === "--host") a.host = String(argv[++i]);
    else if (t === "--port") a.port = Number(argv[++i]);
    else if (t === "--for") {
      const v = String(argv[++i]);
      if (v === "idle" || v === "approval" || v === "input" || v === "any") a.forWhat = v;
    } else if (t === "--timeout") {
      const s = Number(argv[++i]);
      if (Number.isFinite(s) && s > 0) a.timeoutMs = s * 1000;
    } else if (!t.startsWith("-") && a.sessionId === undefined) a.sessionId = t;
  }
  return a;
}

function failUsage(message: string): never {
  console.error(`[makit] ${message}`);
  return process.exit(EXIT_USAGE);
}

/**
 * The exit code a non-running status maps to, or `undefined` if still running.
 * Exported because `ask` needs the *same* rule: a session that is already blocked
 * or exited must be reported, not waited on (D8), and a second copy of this
 * mapping is a second thing to forget.
 */
export function codeForStatus(status: string): number | undefined {
  if (status === "idle") return 0;
  if (status === "awaiting-approval") return EXIT_APPROVAL;
  if (status === "awaiting-input") return EXIT_INPUT;
  if (status === "exited") return EXIT_EXITED;
  return undefined;
}

/**
 * Whether an outcome ends the wait.
 *
 * `--for` narrows which *ongoing* outcome you are waiting for — but it cannot make
 * a dead session worth waiting on, so a **terminal** state always ends the wait.
 * `exited` is terminal (the agent is gone; no later turn can happen), while `idle`
 * and the two blocked states are not: a session that went idle may run again, and
 * one blocked on a human may be answered and continue. Treating `exited` as
 * narrowable is what let `wait --for idle` block forever on a crashed agent.
 */
function wanted(forWhat: WaitFor, code: number): boolean {
  if (code === EXIT_EXITED) return true; // terminal, whatever was asked for
  if (forWhat === "any") return true;
  if (forWhat === "idle") return code === 0;
  if (forWhat === "approval") return code === EXIT_APPROVAL;
  return code === EXIT_INPUT;
}

export interface WaitOutcome {
  code: number;
  message?: string;
}

/**
 * Subscribe and resolve with the first outcome that ends the wait. The `sub` is
 * sent synchronously, so a caller may send the message that starts the turn
 * *after* calling this and still not miss an event (`makit run`, T17).
 *
 * `onEvent` sees every event of the session while waiting — that is how `run`
 * prints the reply without a second subscription.
 *
 * **Everything before the `sub` ack is ignored.** `sub` replays the whole
 * persisted log before acking, so any session that has ever completed a turn
 * hands us a `running` → `idle` pair the instant we subscribe. Counting that
 * would exit `0` having waited for nothing — D8's false success by another route —
 * and would make `makit ask` print the answer to the *previous* question. The ack
 * is the only end-of-replay signal on the wire (`tail` uses it for the same
 * reason); there is no `latestSeq` on any DTO to subtract from.
 */
export function awaitOutcome(
  client: MakitClient,
  sessionId: string,
  opts: { forWhat: WaitFor; timeoutMs?: number; initialStatus?: string; onEvent?: (ev: SessionEvent) => void },
): Promise<WaitOutcome> {
  return new Promise<WaitOutcome>((resolve) => {
    let sawRunning = opts.initialStatus === "running";
    let replayed = false;
    let timer: NodeJS.Timeout | undefined;
    if (opts.timeoutMs !== undefined) {
      timer = setTimeout(() => resolve({ code: EXIT_TIMEOUT, message: "timed out waiting" }), opts.timeoutMs);
      timer.unref();
    }
    const settle = (o: WaitOutcome) => {
      if (timer) clearTimeout(timer);
      resolve(o);
    };

    client.onClose(() => settle({ code: 1, message: "connection closed while waiting" }));
    client.onFrame((m) => {
      if (m.t === "ack" && m.id === SUB_ID) {
        replayed = true;
        return;
      }
      if (!replayed) return; // history, not this turn
      if (m.kind !== "session.event" || !m.event) return;
      const ev = m.event as SessionEvent;
      if (ev.sessionId !== sessionId) return;
      opts.onEvent?.(ev);

      // A failed turn is an *event*, and it wins over the idle that follows it.
      if (ev.kind === "session.error") {
        settle({ code: EXIT_ERROR, message: String(ev.payload.message ?? "session error") });
        return;
      }
      if (ev.kind !== "session.status") return;
      const status = String(ev.payload.status ?? "");
      if (status === "running") {
        sawRunning = true;
        return;
      }
      const code = codeForStatus(status);
      if (code === undefined) return;
      // The edge: a turn is only "complete" if we saw it running. Being blocked
      // or exited is reported whether or not a turn ran.
      if (code === 0 && !sawRunning) return;
      if (!wanted(opts.forWhat, code)) return;
      settle({ code });
    });

    client.send({ t: "sub", id: SUB_ID, sessionId });
  });
}

export async function runWait(argv: string[]): Promise<void> {
  const args = parseWaitArgs(argv);
  const sessionId = args.sessionId;
  if (!sessionId) {
    return failUsage("usage: makit wait <id> [--for idle|approval|input|any] [--timeout S]");
  }

  const client = await connectCli(args);
  const snapshot = await client.awaitSnapshot();
  const current = snapshot.sessions.find((s) => s.id === sessionId);
  if (!current) {
    console.error(`[makit] no such session: ${sessionId}`);
    client.close();
    return process.exit(1);
  }

  // A session already blocked or exited needs no edge — it is already waiting.
  const initial = codeForStatus(current.status);
  if (initial !== undefined && initial !== 0 && wanted(args.forWhat, initial)) {
    client.close();
    return process.exit(initial);
  }

  const outcome = await awaitOutcome(client, sessionId, {
    forWhat: args.forWhat,
    timeoutMs: args.timeoutMs,
    initialStatus: current.status,
  });

  client.close();
  if (outcome.message) console.error(`[makit] ${outcome.message}`);
  process.exit(outcome.code);
}
