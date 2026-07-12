import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import type { ChildProcess } from "node:child_process";

import { PiAdapter } from "./pi.js";
import type { AdapterEvent } from "./adapter.js";

const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * A fake ChildProcess: an EventEmitter with pipe-shaped stdio streams. Enough
 * for PiAdapter.ensureProcess to bind its listeners. [onSpawn] runs once the
 * adapter has attached its handlers, so a test can emit 'error'/'exit' into a
 * fully-wired child.
 */
function fakeSpawn(
  onSpawn?: (child: any) => void,
): { spawn: (typeof import("node:child_process"))["spawn"]; children: any[] } {
  const children: any[] = [];
  const spawn = (() => {
    const child: any = new EventEmitter();
    child.killed = false;
    child.stdin = Object.assign(new EventEmitter(), {
      destroyed: false,
      write: () => true,
    });
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();
    child.kill = () => {};
    children.push(child);
    // Fire after the caller has attached its 'error'/'exit'/stream listeners.
    setImmediate(() => onSpawn?.(child));
    return child as unknown as ChildProcess;
  }) as unknown as (typeof import("node:child_process"))["spawn"];
  return { spawn, children };
}

test("a spawn failure surfaces session.error+exited instead of crashing the daemon", async () => {
  const { spawn } = fakeSpawn((child) =>
    child.emit("error", Object.assign(new Error("spawn pi ENOENT"), { code: "ENOENT" })),
  );
  const adapter = new PiAdapter({ spawn });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));

  // Must not throw / must not emit an unhandled 'error' that aborts the process.
  await adapter.start({ cwd: "/tmp", sessionId: "s1" });
  await delay(50);

  const kinds = events.map((e) => e.kind);
  assert.ok(kinds.includes("session.error"), `expected session.error, got ${kinds.join(",")}`);
  assert.ok(
    events.some(
      (e) => e.kind === "session.status" && (e.payload as any).status === "exited",
    ),
    "expected an exited status event",
  );
  // The dead child is dropped so the next send() can re-spawn.
  assert.equal((adapter as any).child, undefined);
});

test("an EPIPE on pi's stdin does not crash the daemon", async () => {
  const { spawn, children } = fakeSpawn();
  const adapter = new PiAdapter({ spawn });
  await adapter.start({ cwd: "/tmp", sessionId: "s2" });
  const child = children[0]!;

  // A write to a broken pipe surfaces as an async 'error' on stdin. With no
  // listener this would be an unhandled 'error' → process crash.
  assert.doesNotThrow(() =>
    child.stdin.emit("error", Object.assign(new Error("write EPIPE"), { code: "EPIPE" })),
  );
  assert.doesNotThrow(() => child.stdout.emit("error", new Error("read EIO")));
  assert.doesNotThrow(() => child.stderr.emit("error", new Error("read EIO")));
});

test("writeCommand swallows a synchronous stdin.write throw", async () => {
  const adapter = new PiAdapter();
  (adapter as any).child = {
    killed: false,
    stdin: {
      destroyed: false,
      write: () => {
        throw Object.assign(new Error("write EPIPE"), { code: "EPIPE" });
      },
    },
  };
  await assert.doesNotReject(adapter.sendAction("name", { name: "x" }));
});

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
