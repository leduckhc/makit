import { test } from "node:test";
import assert from "node:assert/strict";

import { PiAdapter } from "./pi.js";

/** Attach a fake child process that captures everything written to stdin. */
function withFakeStdin(adapter: PiAdapter): string[] {
  const writes: string[] = [];
  (adapter as any).child = {
    killed: false,
    stdin: {
      destroyed: false,
      write: (s: string) => {
        writes.push(s);
        return true;
      },
    },
  };
  return writes;
}

test("setTitle UI request is surfaced as a 'title' event (not swallowed)", async () => {
  const adapter = new PiAdapter();
  const titles: string[] = [];
  adapter.on("title", (t) => titles.push(t));

  await (adapter as any).handleUiRequest({
    type: "extension_ui_request",
    id: "u1",
    method: "setTitle",
    title: "Fix the parser",
  });

  assert.deepEqual(titles, ["Fix the parser"]);
});

test("other fire-and-forget UI methods stay swallowed", async () => {
  const adapter = new PiAdapter();
  const titles: string[] = [];
  adapter.on("title", (t) => titles.push(t));

  for (const method of ["notify", "setStatus", "setWidget", "set_editor_text"]) {
    await (adapter as any).handleUiRequest({ type: "extension_ui_request", id: "x", method });
  }

  assert.deepEqual(titles, []);
});

test("sendAction('name') maps to pi's set_session_name command", async () => {
  const adapter = new PiAdapter();
  const writes = withFakeStdin(adapter);

  await adapter.sendAction("name", { name: "My session" });

  const cmds = writes.map((w) => JSON.parse(w));
  assert.equal(cmds.length, 1);
  assert.equal(cmds[0].type, "set_session_name");
  assert.equal(cmds[0].name, "My session");
});

test("sendAction ignores unknown actions and empty names", async () => {
  const adapter = new PiAdapter();
  const writes = withFakeStdin(adapter);

  await adapter.sendAction("compact");
  await adapter.sendAction("name", { name: "   " });

  assert.deepEqual(writes, []);
});

/** Feed a raw pi RPC line into the adapter's private handler. */
function feed(adapter: PiAdapter, obj: unknown): void {
  (adapter as any).handleLine(JSON.stringify(obj));
}

function msgUpdate(e: Record<string, unknown>) {
  return { type: "message_update", assistantMessageEvent: e };
}

test("thinking is anchored before the answer even when text streams before thinking_end", () => {
  // Reproduces the GPT-5/Responses ordering where the answer's text_delta
  // arrives before the reasoning item's thinking_end. The thinking must still
  // be emitted before the message so the phone renders it above the answer.
  const adapter = new PiAdapter();
  const kinds: string[] = [];
  adapter.on("event", (e) => kinds.push(e.kind));

  feed(adapter, msgUpdate({ type: "thinking_start", contentIndex: 0 }));
  feed(adapter, msgUpdate({ type: "thinking_delta", contentIndex: 0, delta: "reason" }));
  feed(adapter, msgUpdate({ type: "text_start", contentIndex: 1 }));
  feed(adapter, msgUpdate({ type: "text_delta", contentIndex: 1, delta: "answer" }));
  feed(adapter, msgUpdate({ type: "thinking_end", contentIndex: 0, content: "reason" }));
  feed(adapter, msgUpdate({ type: "text_end", contentIndex: 1, content: "answer" }));

  const firstThinking = kinds.findIndex((k) => k.startsWith("agent.thinking"));
  const firstMessage = kinds.findIndex((k) => k.startsWith("agent.message"));
  assert.ok(firstThinking >= 0, "expected a thinking event");
  assert.ok(firstMessage >= 0, "expected a message event");
  assert.ok(
    firstThinking < firstMessage,
    `thinking should be emitted before the answer (kinds=${kinds.join(",")})`,
  );
});
