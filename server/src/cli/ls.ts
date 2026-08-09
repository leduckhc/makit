/**
 * `makit ls` — list sessions (SPEC-46 T7).
 *
 * The first session verb that is a client of the WSS transport (D1): the very
 * same `sessions.snapshot` the app renders, so the terminal cannot drift from
 * the phone. Two contracts live here and every later verb inherits them:
 *
 *   - **D7** — human output by default; `--json` is the wire, unmodified: the
 *     `SessionDTO` array exactly as it arrived, one JSON document on stdout and
 *     nothing else.
 *   - **D8/C4** — the control socket is probed *first* (`requireDaemon`), so a
 *     dead daemon is exit `3` with SPEC-02's message, and a credential the
 *     server refuses is exit `4`. That probe is also where `cli.grant` mints the
 *     CLI's own device, so liveness and credential are one round trip.
 */
import { AuthError } from "./client.js";
import { connectCli, failAuth } from "./connect.js";
import { renderSessionLine } from "./render.js";
import type { SessionDTO } from "../protocol.js";

export interface LsArgs {
  host: string;
  port: number;
  json: boolean;
  archived: boolean;
  projectId?: string;
}

export function parseLsArgs(argv: string[]): LsArgs {
  const a: LsArgs = { host: "127.0.0.1", port: 7777, json: false, archived: false };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i]!;
    if (t === "--host") a.host = String(argv[++i]);
    else if (t === "--port") a.port = Number(argv[++i]);
    else if (t === "--json") a.json = true;
    else if (t === "--archived") a.archived = true;
    else if (t === "--project") a.projectId = String(argv[++i]);
  }
  return a;
}

export async function runLs(argv: string[]): Promise<void> {
  const args = parseLsArgs(argv);

  const client = await connectCli(args);
  try {
    const sessions = args.archived
      ? ((await client.cmd("session.listArchived")).sessions as SessionDTO[]) ?? []
      : (await client.awaitSnapshot()).sessions;
    const shown = args.projectId ? sessions.filter((s) => s.projectId === args.projectId) : sessions;
    if (args.json) {
      console.log(JSON.stringify(shown));
      return;
    }
    if (shown.length === 0) {
      console.log("no sessions");
      return;
    }
    for (const s of shown) console.log(renderSessionLine(s));
  } catch (e) {
    if (e instanceof AuthError) return failAuth(e.message);
    throw e;
  } finally {
    client.close();
  }
}
