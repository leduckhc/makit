/**
 * `makit run` — `new` + `wait` + print, in one command (SPEC-46 T17).
 *
 * The composed form is what automation actually wants: start the work, block
 * until something happens, and let the exit code say what (D8). It reuses
 * `new`'s spawn half and `wait`'s outcome watcher rather than reimplementing
 * either, so the worktree rule (D15) and the edge trigger cannot drift between
 * `makit new … && makit wait …` and `makit run …`.
 *
 * Ordering is the one subtle part: the subscription goes in **between** the
 * spawn and the first message, because `send.message` is what starts the turn —
 * subscribing after it could miss the whole thing.
 */
import { connectCli, failCommand } from "./connect.js";
import { EXIT_USAGE } from "./exit-codes.js";
import { parseNewArgs, spawnFromArgs, type NewArgs } from "./new.js";
import { awaitOutcome, type WaitFor } from "./wait.js";
import { WireError } from "./client.js";
import type { MakitClient } from "./client.js";
import { renderEvent, type RenderState } from "./render.js";
import { stdout } from "./out.js";
import type { SessionEvent } from "../protocol.js";

export interface RunArgs extends NewArgs {
  forWhat: WaitFor;
  timeoutMs?: number;
}

export function parseRunArgs(argv: string[]): RunArgs {
  const base = parseNewArgs(argv);
  const a: RunArgs = { ...base, forWhat: "any" };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i]!;
    if (t === "--for") {
      const v = String(argv[++i]);
      if (v === "idle" || v === "approval" || v === "input" || v === "any") a.forWhat = v;
    } else if (t === "--timeout") {
      const s = Number(argv[++i]);
      if (Number.isFinite(s) && s > 0) a.timeoutMs = s * 1000;
    }
  }
  return a;
}

export async function runRun(argv: string[]): Promise<void> {
  const args = parseRunArgs(argv);
  if (args.message === undefined) {
    console.error("[makit] usage: makit run -m MSG [--agent A] [--for …] [--timeout S] [--json]");
    return process.exit(EXIT_USAGE);
  }

  const client = await connectCli(args);
  // Both composed commands are refusable — the D9 depth/fan-out bound refuses
  // `session.spawn`, a dead or full session refuses `send.message` — and a
  // refusal that escapes would print a stack trace and leave the socket open,
  // so the run would never reach an exit code at all. `new` already unwinds this
  // way; `run` must not be the copy that forgets.
  try {
    await runTurn(client, args);
  } catch (e) {
    if (e instanceof WireError) return failCommand(e);
    throw e;
  } finally {
    client.close();
  }
}

/** The spawn + subscribe + send + wait body, so one `finally` owns the socket. */
async function runTurn(client: MakitClient, args: RunArgs): Promise<never | void> {
  const { sessionId } = await spawnFromArgs(client, args);
  if (args.json) console.log(JSON.stringify({ sessionId }));
  else console.log(`[makit] session ${sessionId}`);

  // Subscribe first (synchronously inside `awaitOutcome`), then send the message
  // that starts the turn, then wait for the outcome.
  let st: RenderState = {};
  const waiting = awaitOutcome(client, sessionId, {
    forWhat: args.forWhat,
    timeoutMs: args.timeoutMs,
    initialStatus: "idle",
    onEvent: (ev: SessionEvent) => {
      if (args.json) {
        console.log(JSON.stringify(ev));
        return;
      }
      const r = renderEvent(ev, st);
      st = r.st;
      if (r.out) stdout.write(r.out);
    },
  });
  await client.cmd("send.message", { sessionId, text: args.message });
  const outcome = await waiting;

  // Closed here as well as in the caller's `finally`: `process.exit` terminates
  // the process synchronously, so the `finally` never runs on this path.
  client.close();
  if (outcome.message) console.error(`[makit] ${outcome.message}`);
  process.exit(outcome.code);
}
