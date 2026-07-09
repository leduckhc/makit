import { test } from "node:test";
import assert from "node:assert/strict";
import { parsePaneInfo } from "./herdr.js";

test("parsePaneInfo extracts session path, cwd, agent", () => {
  const stdout = JSON.stringify({
    id: "cli:pane:get",
    result: {
      type: "pane_info",
      pane: {
        agent: "pi",
        agent_session: {
          agent: "pi",
          kind: "path",
          source: "herdr:pi",
          value: "/Users/le/.pi/agent/sessions/--x--/abc.jsonl",
        },
        cwd: "/Users/le/Work/Vibe/makit/server",
        pane_id: "w7:p2",
      },
    },
  });
  const info = parsePaneInfo(stdout);
  assert.equal(info.sessionPath, "/Users/le/.pi/agent/sessions/--x--/abc.jsonl");
  assert.equal(info.cwd, "/Users/le/Work/Vibe/makit/server");
  assert.equal(info.agent, "pi");
});

test("parsePaneInfo returns {} when no agent session (kind not path)", () => {
  const stdout = JSON.stringify({
    result: { pane: { agent_status: "unknown", cwd: "/tmp" } },
  });
  const info = parsePaneInfo(stdout);
  assert.equal(info.sessionPath, undefined);
  assert.equal(info.cwd, "/tmp");
});

test("parsePaneInfo never throws on garbage", () => {
  assert.deepEqual(parsePaneInfo("not json"), {});
  assert.deepEqual(parsePaneInfo("{}"), {});
});
