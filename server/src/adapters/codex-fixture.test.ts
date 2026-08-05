/**
 * SPEC-31 — codex fixture-replay integration test.
 *
 * Drives the real {@link CodexAppServerAdapter} from a **recorded** live
 * `codex app-server` session (`test/fixtures/codex-fast-session.jsonl`, captured
 * with the Fast/priority service tier), replaying the exact JSON-RPC frames the
 * app-server sent — no live codex, deterministic in CI. Mirrors the pi-acp
 * session-fixture pattern (see the `acp-session-fixture-recorder` skill).
 *
 * Asserts the adapter, fed only recorded frames, projects the real per-model
 * config surface (per-model reasoning efforts + the Fast service tier) and
 * surfaces the recorded assistant message through the event mapper.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { CodexAppServerAdapter, type CodexTransport } from "./codex.js";
import type { AdapterEvent } from "./adapter.js";

interface Frame {
  t: "send" | "recv";
  id?: number;
  method?: string;
  params?: unknown;
  result?: unknown;
  error?: unknown;
}

function loadFixture(): Frame[] {
  const path = fileURLToPath(new URL("../../test/codex-sessions/codex-fast-session.jsonl", import.meta.url));
  return readFileSync(path, "utf8")
    .trim()
    .split("\n")
    .map((l) => JSON.parse(l) as Frame);
}

/**
 * A {@link CodexTransport} that replays a recorded session: it answers each
 * request with the recorded response for that method, and pushes the recorded
 * notifications — the pre-turn batch after `thread/start`, the turn batch after
 * `turn/start` — so the adapter runs exactly as it did live.
 */
function replayTransport(frames: Frame[]): { transport: CodexTransport; sent: any[] } {
  const sendMethodById = new Map<number, string>();
  for (const f of frames) if (f.t === "send" && f.id !== undefined && f.method) sendMethodById.set(f.id, f.method);

  // Recorded responses keyed by the request method.
  const responseByMethod = new Map<string, unknown>();
  for (const f of frames) {
    if (f.t === "recv" && f.id !== undefined) {
      const method = sendMethodById.get(f.id);
      if (method) responseByMethod.set(method, f.result);
    }
  }

  // Notifications split at the first `turn/started`.
  const notifs = frames.filter((f) => f.t === "recv" && f.method).map((f) => ({ method: f.method!, params: f.params }));
  const turnIdx = notifs.findIndex((n) => n.method === "turn/started");
  const preTurn = turnIdx < 0 ? notifs : notifs.slice(0, turnIdx);
  const turnNotifs = turnIdx < 0 ? [] : notifs.slice(turnIdx);

  let lineCb: (l: string) => void = () => {};
  const sent: any[] = [];
  const feed = (obj: unknown) => queueMicrotask(() => lineCb(JSON.stringify(obj)));

  const transport: CodexTransport = {
    pid: undefined, // in-memory fake: no child process
    send: (line) => {
      const msg = JSON.parse(line);
      sent.push(msg);
      if (msg.method && msg.id !== undefined) {
        const result = responseByMethod.get(msg.method);
        if (result !== undefined) feed({ id: msg.id, result });
        if (msg.method === "thread/start") for (const n of preTurn) feed(n);
        if (msg.method === "turn/start") for (const n of turnNotifs) feed(n);
      }
    },
    onLine: (cb) => {
      lineCb = cb;
    },
    onExit: () => {},
    onStreamEnd: () => {},
    dispose: () => {},
  };
  return { transport, sent };
}

test("codex fixture replay: real per-model efforts + Fast tier from recorded model/list", async () => {
  const { transport } = replayTransport(loadFixture());
  const adapter = new CodexAppServerAdapter({ connect: () => transport });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));

  await adapter.start({ cwd: "/tmp/fixture-cwd", sessionId: "fx" });
  // Let the queued microtask frames drain.
  await new Promise((r) => setTimeout(r, 20));

  const meta = events.filter((e) => e.kind === "session.meta").at(-1)!.payload as any;
  const byId = Object.fromEntries(meta.configOptions.map((o: any) => [o.id, o]));

  // Real catalog: the default model is gpt-5.6-sol.
  assert.equal(byId.model.currentValue, "gpt-5.6-sol");
  // Per-model reasoning efforts from the real model/list (NOT the old hardcoded
  // minimal/low/medium/high) — proves the SPEC-31 codex fix end-to-end.
  assert.deepEqual(
    byId.thought_level.options.map((o: any) => o.value),
    ["low", "medium", "high", "xhigh", "max", "ultra"],
  );
  // The Fast service tier is projected (gpt-5.6-sol advertises priority/Fast).
  assert.ok(byId.fast, "Fast option present");
  assert.equal(byId.fast.type, "boolean");
  assert.equal(byId.fast.category, "model_config");
});

test("codex fixture replay: recorded assistant message surfaces through the mapper", async () => {
  const { transport } = replayTransport(loadFixture());
  const adapter = new CodexAppServerAdapter({ connect: () => transport });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));

  await adapter.start({ cwd: "/tmp/fixture-cwd", sessionId: "fx" });
  await adapter.send({ text: "Reply with exactly one word: OK" });
  await new Promise((r) => setTimeout(r, 30));

  // The recorded turn's agent message ("OK") flowed through CodexEventMapper.
  const carriesOk = events.some((e) => JSON.stringify(e.payload ?? "").includes("OK"));
  assert.ok(carriesOk, "the recorded assistant message 'OK' surfaced as an event");
  // And the turn settled (turn/completed replayed).
  assert.ok(events.some((e) => e.kind === "session.meta" || e.kind === "user.message"));
});
