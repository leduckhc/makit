import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, utimesSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { piSessionsDir, listPiSessions, parseTranscript } from "./pi-sessions.js";

test("piSessionsDir applies pi's slug algorithm", () => {
  assert.equal(
    piSessionsDir("/Users/le/Work/Vibe/pino", "/agent"),
    join("/agent", "sessions", "--Users-le-Work-Vibe-pino--"),
  );
  assert.equal(
    piSessionsDir("/private/tmp/subagent-demo", "/agent"),
    join("/agent", "sessions", "--private-tmp-subagent-demo--"),
  );
});

test("listPiSessions parses headers, filters by cwd, sorts by mtime desc", () => {
  const agentDir = mkdtempSync(join(tmpdir(), "pino-agent-"));
  try {
    const cwd = "/work/proj";
    const dir = piSessionsDir(cwd, agentDir);
    mkdirSync(dir, { recursive: true });

    const older = join(dir, "2026-01-01T00-00-00-000Z_aaaa.jsonl");
    const newer = join(dir, "2026-02-02T00-00-00-000Z_bbbb.jsonl");
    // Also a session for a different cwd → must be filtered out.
    const foreign = join(dir, "2026-03-03T00-00-00-000Z_cccc.jsonl");

    writeFileSync(
      older,
      [
        JSON.stringify({ type: "session", version: 3, id: "aaaa", timestamp: "2026-01-01T00:00:00.000Z", cwd }),
        JSON.stringify({ type: "message", message: { role: "user", content: [{ type: "text", text: "first task here" }] } }),
        JSON.stringify({ type: "message", message: { role: "assistant", content: [{ type: "text", text: "ok" }] } }),
      ].join("\n") + "\n",
    );
    writeFileSync(
      newer,
      [
        JSON.stringify({ type: "session", version: 3, id: "bbbb", timestamp: "2026-02-02T00:00:00.000Z", cwd }),
        JSON.stringify({ type: "message", message: { role: "user", content: [{ type: "text", text: "second task" }] } }),
      ].join("\n") + "\n",
    );
    writeFileSync(
      foreign,
      JSON.stringify({ type: "session", version: 3, id: "cccc", timestamp: "2026-03-03T00:00:00.000Z", cwd: "/other/place" }) + "\n",
    );

    utimesSync(older, new Date(1000), new Date(1000));
    utimesSync(newer, new Date(2000), new Date(2000));
    utimesSync(foreign, new Date(3000), new Date(3000));

    const list = listPiSessions(cwd, agentDir);
    assert.equal(list.length, 2);
    // Sorted by mtime desc → newer first.
    assert.equal(list[0].piSessionId, "bbbb");
    assert.equal(list[0].preview, "second task");
    assert.equal(list[0].messageCount, 1);
    assert.equal(list[1].piSessionId, "aaaa");
    assert.equal(list[1].preview, "first task here");
    assert.equal(list[1].messageCount, 2);
  } finally {
    rmSync(agentDir, { recursive: true, force: true });
  }
});

test("listPiSessions returns [] when the slug dir is absent", () => {
  const agentDir = mkdtempSync(join(tmpdir(), "pino-agent-"));
  try {
    assert.deepEqual(listPiSessions("/nope", agentDir), []);
  } finally {
    rmSync(agentDir, { recursive: true, force: true });
  }
});

test("parseTranscript maps user/assistant/tool records to AdapterEvents", () => {
  const agentDir = mkdtempSync(join(tmpdir(), "pino-agent-"));
  try {
    const file = join(agentDir, "t.jsonl");
    writeFileSync(
      file,
      [
        JSON.stringify({ type: "session", version: 3, id: "s1", timestamp: "2026-01-01T00:00:00.000Z", cwd: "/x" }),
        JSON.stringify({ type: "message", message: { role: "user", content: [{ type: "text", text: "hello" }] } }),
        JSON.stringify({
          type: "message",
          message: {
            role: "assistant",
            content: [
              { type: "thinking", thinking: "hmm" },
              { type: "text", text: "hi there" },
              { type: "toolCall", id: "call_1", name: "bash", arguments: { command: "ls" } },
            ],
          },
        }),
        JSON.stringify({
          type: "message",
          message: { role: "toolResult", toolCallId: "call_1", toolName: "bash", content: [{ type: "text", text: "file.txt" }] },
        }),
        JSON.stringify({ type: "model_change", model: "x" }),
        "{ this is not valid json",
      ].join("\n") + "\n",
    );

    const events = parseTranscript(file);
    assert.equal(events.length, 4);
    assert.equal(events[0].kind, "user.message");
    assert.equal(events[0].payload.text, "hello");
    assert.equal(events[1].kind, "agent.message");
    assert.equal(events[1].payload.text, "hi there");
    assert.equal(events[2].kind, "tool.call.start");
    assert.equal(events[2].payload.callId, "call_1");
    assert.equal(events[2].payload.name, "bash");
    assert.deepEqual(events[2].payload.args, { command: "ls" });
    assert.equal(events[3].kind, "tool.call.end");
    assert.equal(events[3].payload.callId, "call_1");
    assert.equal(events[3].payload.output, "file.txt");
  } finally {
    rmSync(agentDir, { recursive: true, force: true });
  }
});

test("parseTranscript never throws on a missing file", () => {
  assert.deepEqual(parseTranscript("/no/such/file.jsonl"), []);
});
