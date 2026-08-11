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
import { withClient } from "./connect.js";
import { renderSessionLine } from "./render.js";
import type { SessionDTO } from "../protocol.js";
import { parseFlags, str, int, bool } from "./flags.js";

export interface LsArgs {
  host: string;
  port: number;
  json: boolean;
  closed: boolean;
  projectId?: string;
}

export function parseLsArgs(argv: string[]): LsArgs {
  const p = parseFlags(argv, {
    host: { type: "string", def: "127.0.0.1" },
    port: { type: "int", def: 7777 },
    json: { type: "bool" },
    closed: { type: "bool" },
    project: { type: "string" },
  });
  return {
    host: str(p, "host")!,
    port: int(p, "port")!,
    json: bool(p, "json"),
    closed: bool(p, "closed"),
    projectId: str(p, "project"),
  };
}

export async function runLs(argv: string[]): Promise<void> {
  const args = parseLsArgs(argv);

  await withClient(args, async (client) => {
    const sessions = args.closed
      ? ((await client.cmd("session.listClosed")).sessions as SessionDTO[]) ?? []
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
  });
}
