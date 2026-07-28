/**
 * replay-acp-session — feed a recorded ACP fixture (see record-acp-session.ts)
 * through the REAL {@link AcpEventMapper} and emit the normalized makit
 * `AdapterEvent`s. This is the deterministic seam for testing UI changes: the
 * app consumes exactly these events (over the WS transport → foldEvents).
 *
 *   node_modules/.bin/tsx test/replay-acp-session.ts <fixture.jsonl> [--events out.json]
 *
 * With --events it writes the normalized event list as a JSON fixture the app
 * can replay through foldEvents in a widget test.
 */

import { readFileSync, writeFileSync } from "node:fs";
import { AcpEventMapper } from "../src/adapters/acp-map.js";
import type { AdapterEvent } from "../src/adapters/adapter.js";
import type { SessionUpdate } from "@agentclientprotocol/sdk";

export function replayFixture(jsonl: string): AdapterEvent[] {
  const events: AdapterEvent[] = [];
  const mapper = new AcpEventMapper({ emit: (e) => events.push(e) });
  for (const line of jsonl.split("\n")) {
    if (!line.trim()) continue;
    const o = JSON.parse(line) as { t: string; update?: SessionUpdate };
    if (o.t === "update" && o.update) mapper.handle(o.update);
    if (o.t === "stopReason") mapper.endTurn();
  }
  return events;
}

if (process.argv[1]?.endsWith("replay-acp-session.ts")) {
  const path = process.argv[2];
  if (!path) throw new Error("usage: replay-acp-session.ts <fixture.jsonl> [--events out.json]");
  const events = replayFixture(readFileSync(path, "utf8"));
  for (const e of events) {
    const p = e.payload as Record<string, unknown>;
    const detail =
      e.kind === "tool.call.start"
        ? `name=${JSON.stringify(p.name)} args=${JSON.stringify(p.args)}`
        : e.kind === "tool.call.end"
          ? `exit=${p.exitCode} summary=${JSON.stringify(p.summary)}`
          : e.kind === "tool.call.delta"
            ? `chunk=${JSON.stringify(p.chunk)}`
            : e.kind.startsWith("agent.")
              ? JSON.stringify(String(p.text ?? p.chunk ?? "").slice(0, 60))
              : "";
    console.log(e.kind.padEnd(22), detail);
  }
  const outIdx = process.argv.indexOf("--events");
  if (outIdx >= 0 && process.argv[outIdx + 1]) {
    // Emit app-ready SessionEvent JSON ({seq, sessionId, ts, kind, payload}) so
    // the Flutter app can replay it through foldEvents in a widget test.
    const appEvents = events.map((e, i) => ({
      seq: i,
      sessionId: "replay",
      ts: e.ts,
      kind: e.kind,
      payload: e.payload,
    }));
    writeFileSync(process.argv[outIdx + 1], JSON.stringify(appEvents, null, 2));
    console.error(`[replay] wrote ${events.length} events → ${process.argv[outIdx + 1]}`);
  }
}
