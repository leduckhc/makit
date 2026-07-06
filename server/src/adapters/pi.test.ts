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
