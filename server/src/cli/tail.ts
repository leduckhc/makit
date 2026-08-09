/**
 * `makit tail <id> [-f] [--since SEQ] [--json]` — replay a session's events and
 * optionally keep streaming (SPEC-46 T14). A thin client of `sub {fromSeq}`.
 *
 * Without `-f`: print the replay and exit `0` — the `sub` ack marks the end of
 * history (the server replays every event, then acks), so that is the cursor to
 * stop on. With `-f`: keep streaming until the connection ends (Ctrl-C).
 *
 * Output contract (D7): `--json` is one `SessionEvent` per line, exactly as it
 * arrived on the wire — no CLI projection. Human output goes through the shared
 * `renderEvent`, the same renderer `attach` uses, so the two cannot drift.
 */
import { renderEvent, type RenderState } from "./render.js";
import { stdout } from "./out.js";
import { connectCli } from "./connect.js";
import { EXIT_USAGE } from "./exit-codes.js";
import type { SessionEvent } from "../protocol.js";

const SUB_ID = "sub";

export interface TailArgs {
  host: string;
  port: number;
  sessionId?: string;
  follow: boolean;
  since?: number;
  json: boolean;
}

export function parseTailArgs(argv: string[]): TailArgs {
  const a: TailArgs = { host: "127.0.0.1", port: 7777, follow: false, json: false };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i]!;
    if (t === "--host") a.host = String(argv[++i]);
    else if (t === "--port") a.port = Number(argv[++i]);
    else if (t === "-f" || t === "--follow") a.follow = true;
    else if (t === "--since") a.since = Number(argv[++i]);
    else if (t === "--json") a.json = true;
    else if (!t.startsWith("-") && a.sessionId === undefined) a.sessionId = t;
  }
  return a;
}

function failUsage(message: string): never {
  console.error(`[makit] ${message}`);
  return process.exit(EXIT_USAGE);
}

export async function runTail(argv: string[]): Promise<void> {
  const args = parseTailArgs(argv);
  if (!args.sessionId) return failUsage("usage: makit tail <id> [-f] [--since SEQ] [--json]");

  const client = await connectCli(args);
  let st: RenderState = {};
  let exitCode = 0;

  await new Promise<void>((resolve) => {
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      resolve();
    };

    client.onClose(finish);
    client.onFrame((m) => {
      if (m.t === "err") {
        const message = typeof m.message === "string" ? m.message : "request failed";
        console.error(`[makit] ${message}`);
        exitCode = 1;
        finish();
        return;
      }
      // The `sub` ack lands after the full history replay: end of the cursor.
      if (m.t === "ack" && m.id === SUB_ID) {
        if (!args.follow) finish();
        return;
      }
      if (m.t === "event" && m.kind === "session.event" && m.event) {
        const e = m.event as SessionEvent;
        if (e.sessionId !== args.sessionId) return;
        if (args.json) {
          console.log(JSON.stringify(e));
        } else {
          const r = renderEvent(e, st);
          st = r.st;
          if (r.out) stdout.write(r.out);
        }
      }
    });

    client.send({ t: "sub", id: SUB_ID, sessionId: args.sessionId, fromSeq: args.since ?? 0 });
  });

  client.close();
  if (exitCode !== 0) process.exit(exitCode);
}
