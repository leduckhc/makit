/**
 * replay-acp-session — feed a recorded ACP session (see record-acp-session.ts)
 * through the REAL {@link AcpEventMapper} and emit the normalized makit
 * `AdapterEvent`s. This is the deterministic seam for testing UI changes: the
 * app consumes exactly these events (over the WS transport → foldEvents).
 *
 *   node_modules/.bin/tsx test/replay-acp-session.ts test/acp-sessions/bash.jsonl
 *
 * Add `--write` to (re)generate the shared `*.events.json` fixture that both
 * server (acp-fixtures.test.ts) and app (acp_replay_test.dart) replay:
 *
 *   node_modules/.bin/tsx test/replay-acp-session.ts --write            # all sessions
 *   node_modules/.bin/tsx test/replay-acp-session.ts --write bash       # just one
 */

import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { AcpEventMapper } from "../src/adapters/acp-map.js";
import type { AdapterEvent } from "../src/adapters/adapter.js";
import type { SessionUpdate } from "@agentclientprotocol/sdk";

const here = dirname(fileURLToPath(import.meta.url));
/** Raw `pi-acp` wire recordings (server-only input). */
export const sessionsDir = resolve(here, "acp-sessions");
/**
 * The generated `*.events.json` fixtures, duplicated byte-identically into the
 * app so both sides replay the same events (enforced by Protocol Contract CI).
 */
export const fixtureDirs = [resolve(here, "fixtures/acp"), resolve(here, "../../app/test/fixtures/acp")];

/** Names of every recorded session, e.g. `["ask-user", "bash", …]`. */
export function sessionNames(): string[] {
  return readdirSync(sessionsDir)
    .filter((f) => f.endsWith(".jsonl"))
    .map((f) => f.replace(/\.jsonl$/, ""))
    .sort();
}

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

/**
 * Project mapper output into the app-facing `SessionEvent` shape
 * (`{seq, sessionId, ts, kind, payload}`), with every wall-clock timestamp and
 * generated id replaced by a stable counter. Without that the output changes on
 * every run (`Date.now()`, `am-<random>-0`) and the fixture could never be
 * byte-compared to catch staleness.
 */
export function toAppEvents(events: AdapterEvent[]): unknown[] {
  const ids = new Map<string, string>();
  const stableId = (raw: string, prefix: string): string => {
    const seen = ids.get(raw);
    if (seen) return seen;
    const next = `${prefix}-${ids.size + 1}`;
    ids.set(raw, next);
    return next;
  };
  return events.map((e, i) => {
    const payload: Record<string, unknown> = { ...(e.payload as Record<string, unknown>) };
    if (typeof payload.msgId === "string") payload.msgId = stableId(payload.msgId, "msg");
    if (typeof payload.thinkId === "string") payload.thinkId = stableId(payload.thinkId, "think");
    return { seq: i, sessionId: "replay", ts: i, kind: e.kind, payload };
  });
}

/** The exact bytes a `<name>.events.json` fixture must contain. */
export function renderFixture(name: string): string {
  const jsonl = readFileSync(join(sessionsDir, `${name}.jsonl`), "utf8");
  return JSON.stringify(toAppEvents(replayFixture(jsonl)), null, 2) + "\n";
}

function printSummary(events: AdapterEvent[]): void {
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
}

if (process.argv[1]?.endsWith("replay-acp-session.ts")) {
  const args = process.argv.slice(2);
  if (args.includes("--write")) {
    const wanted = args.filter((a) => a !== "--write");
    for (const name of wanted.length > 0 ? wanted : sessionNames()) {
      const body = renderFixture(name);
      for (const dir of fixtureDirs) writeFileSync(join(dir, `${name}.events.json`), body);
      console.error(`[replay] wrote ${name}.events.json → ${fixtureDirs.length} fixture dirs`);
    }
  } else {
    const path = args[0];
    if (!path) throw new Error("usage: replay-acp-session.ts <session.jsonl> | --write [name…]");
    printSummary(replayFixture(readFileSync(path, "utf8")));
  }
}
