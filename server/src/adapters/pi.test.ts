import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import type { ChildProcess } from "node:child_process";

import { PiAdapter } from "./pi.js";
import type { AdapterEvent } from "./adapter.js";

const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * Polls [writes] until the adapter's boot commands (get_state +
 * get_available_models) have both been issued, instead of racing a fixed
 * timer against pi's settle delay. Rejects if they never arrive.
 */
async function waitForBoot(writes: string[], timeoutMs = 2000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const cmds = writes.map((w) => JSON.parse(w));
    if (
      cmds.some((c) => c.type === "get_state") &&
      cmds.some((c) => c.type === "get_available_models")
    ) {
      return;
    }
    await delay(5);
  }
  throw new Error("timed out waiting for boot commands (get_state + get_available_models)");
}

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

test("emits session.meta from get_state + get_available_models and maps model/thinking actions", async () => {
  const writes: string[] = [];
  const { spawn, children } = fakeSpawn((child) => {
    child.stdin.write = (s: string) => {
      writes.push(s);
      return true;
    };
  });
  const adapter = new PiAdapter({ spawn });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));

  await adapter.start({ cwd: "/tmp", sessionId: "s1" });
  await waitForBoot(writes); // wait until boot has queried pi, not a fixed timer

  // At boot the adapter asks pi for its state + selectable models.
  const booted = writes.map((w) => JSON.parse(w));
  assert.ok(booted.some((c) => c.type === "get_state"), "expected get_state");
  assert.ok(
    booted.some((c) => c.type === "get_available_models"),
    "expected get_available_models",
  );

  const child = children[0]!;
  const line = (o: unknown) => child.stdout.emit("data", JSON.stringify(o) + "\n");
  line({
    type: "response",
    command: "get_state",
    success: true,
    data: { model: { provider: "openai", id: "gpt-5", name: "GPT-5" }, thinkingLevel: "medium" },
  });
  line({
    type: "response",
    command: "get_available_models",
    success: true,
    data: {
      models: [
        { provider: "openai", id: "gpt-5", name: "GPT-5" },
        { provider: "anthropic", id: "claude", name: "Claude" },
      ],
    },
  });

  const meta = events.filter((e) => e.kind === "session.meta").at(-1);
  assert.ok(meta, "expected a session.meta event");
  const payload = meta!.payload as any;
  assert.equal(payload.thinking, "medium");
  assert.equal(payload.model.id, "gpt-5");
  assert.equal(payload.models.length, 2);

  // The composer selectors' actions map to pi's rpc commands.
  writes.length = 0;
  await adapter.sendAction("model", { provider: "anthropic", id: "claude" });
  await adapter.sendAction("thinking", { level: "high" });
  const cmds = writes.map((w) => JSON.parse(w));
  assert.ok(
    cmds.some((c) => c.type === "set_model" && c.provider === "anthropic" && c.modelId === "claude"),
    "expected set_model",
  );
  assert.ok(
    cmds.some((c) => c.type === "set_thinking_level" && c.level === "high"),
    "expected set_thinking_level",
  );
});

test("set_model / set_thinking_level responses adopt the model and re-query state", async () => {
  const writes: string[] = [];
  const { spawn, children } = fakeSpawn((child) => {
    child.stdin.write = (s: string) => {
      writes.push(s);
      return true;
    };
  });
  const adapter = new PiAdapter({ spawn });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));

  await adapter.start({ cwd: "/tmp", sessionId: "s1" });
  await waitForBoot(writes); // wait for delayed boot commands before clearing writes

  const child = children[0]!;
  const line = (o: unknown) => child.stdout.emit("data", JSON.stringify(o) + "\n");

  // set_model's response payload IS the new Model (per docs/rpc.md): the branch
  // normalizes + adopts it, then re-queries state.
  writes.length = 0;
  line({
    type: "response",
    command: "set_model",
    success: true,
    data: { provider: "anthropic", id: "claude", name: "Claude" },
  });
  const afterSetModel = writes.map((w) => JSON.parse(w));
  assert.ok(afterSetModel.some((c) => c.type === "get_state"), "set_model re-queries get_state");
  assert.ok(
    afterSetModel.some((c) => c.type === "get_available_models"),
    "set_model re-queries get_available_models",
  );

  // The adopted model surfaces on the next pushMeta (here via the models
  // response, which does not overwrite metaModel).
  line({
    type: "response",
    command: "get_available_models",
    success: true,
    data: { models: [{ provider: "anthropic", id: "claude", name: "Claude" }] },
  });
  const metaAfterModel = events.filter((e) => e.kind === "session.meta").at(-1);
  assert.equal((metaAfterModel!.payload as any).model.id, "claude", "set_model adopted the returned model");

  // set_thinking_level has no payload — it only re-queries state.
  writes.length = 0;
  line({ type: "response", command: "set_thinking_level", success: true });
  const afterSetThinking = writes.map((w) => JSON.parse(w));
  assert.ok(afterSetThinking.some((c) => c.type === "get_state"), "set_thinking_level re-queries get_state");
  assert.ok(
    afterSetThinking.some((c) => c.type === "get_available_models"),
    "set_thinking_level re-queries get_available_models",
  );
});

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

// ---------------------------------------------------------------------------
// Integration: the ctx.ui.* → extension_ui_request interceptor ("Path B").
//
// This is the ONLY path that carries pi-ask-user's rpc fallback (ask_user →
// ctx.ui.select/input) to the app now that the makit-pi connector + HTTP bridge
// were removed. We drive a raw pi rpc line through handleLine (parse + route +
// intercept), answer via a stub askUser (the app), and assert the exact
// extension_ui_response written back to pi's stdin.
// ---------------------------------------------------------------------------

import type { UICall, UIResponse } from "../uicall.js";

/** Wire a stub askUser (the "app") + capture stdin, then feed a raw pi line. */
function wireInterceptor(
  answer: UIResponse | ((call: UICall) => UIResponse),
): { adapter: PiAdapter; calls: UICall[]; writes: string[] } {
  const adapter = new PiAdapter();
  (adapter as any).sessionId = "sess-int";
  const calls: UICall[] = [];
  (adapter as any).askUser = async (call: UICall): Promise<UIResponse> => {
    calls.push(call);
    return typeof answer === "function" ? answer(call) : answer;
  };
  const writes = withFakeStdin(adapter);
  return { adapter, calls, writes };
}

function feedLine(adapter: PiAdapter, obj: unknown): void {
  (adapter as any).handleLine(JSON.stringify(obj));
}

test("select UI request round-trips: askUserQuestion → extension_ui_response {value}", async () => {
  const { adapter, calls, writes } = wireInterceptor({
    kind: "askUserQuestion",
    indices: [0],
    answers: ["Yes"],
  } as UIResponse);

  // Exactly what pi-ask-user's rpc fallback (ctx.ui.select) makes pi emit.
  feedLine(adapter, {
    type: "extension_ui_request",
    id: "ui-sel",
    method: "select",
    title: "Pick one?",
    options: ["Yes", "No"],
  });
  await delay(10);

  assert.equal(calls.length, 1, "askUser should be called exactly once");
  assert.equal(calls[0].kind, "askUserQuestion");
  assert.equal((calls[0] as any).questions[0].question, "Pick one?");
  assert.deepEqual(
    (calls[0] as any).questions[0].options.map((o: any) => o.label),
    ["Yes", "No"],
  );

  const cmds = writes.map((w) => JSON.parse(w));
  assert.equal(cmds.length, 1);
  assert.deepEqual(cmds[0], { type: "extension_ui_response", id: "ui-sel", value: "Yes" });
});

test("input UI request round-trips: input UICall → extension_ui_response {value}", async () => {
  const { adapter, calls, writes } = wireInterceptor({
    kind: "input",
    value: "typed answer",
  } as UIResponse);

  feedLine(adapter, {
    type: "extension_ui_request",
    id: "ui-in",
    method: "input",
    title: "Your answer",
    placeholder: "type...",
  });
  await delay(10);

  assert.equal(calls[0].kind, "input");
  assert.equal((calls[0] as any).multiline, false);
  const cmds = writes.map((w) => JSON.parse(w));
  assert.deepEqual(cmds[0], { type: "extension_ui_response", id: "ui-in", value: "typed answer" });
});

test("editor UI request maps to multiline input", async () => {
  const { adapter, calls, writes } = wireInterceptor({ kind: "input", value: "body" } as UIResponse);
  feedLine(adapter, { type: "extension_ui_request", id: "ui-ed", method: "editor", title: "Edit" });
  await delay(10);
  assert.equal(calls[0].kind, "input");
  assert.equal((calls[0] as any).multiline, true);
  assert.deepEqual(JSON.parse(writes[0]), { type: "extension_ui_response", id: "ui-ed", value: "body" });
});

test("confirm UI request round-trips: confirmAction → extension_ui_response {confirmed}", async () => {
  const { adapter, calls, writes } = wireInterceptor({
    kind: "confirmAction",
    approved: true,
  } as UIResponse);

  feedLine(adapter, {
    type: "extension_ui_request",
    id: "ui-cf",
    method: "confirm",
    title: "Deploy?",
    message: "to prod",
  });
  await delay(10);

  assert.equal(calls[0].kind, "confirmAction");
  assert.deepEqual(JSON.parse(writes[0]), { type: "extension_ui_response", id: "ui-cf", confirmed: true });
});

// ---------------------------------------------------------------------------
// Regression guards.
// ---------------------------------------------------------------------------

test("regression: a cancelled answer maps to extension_ui_response {cancelled:true}", async () => {
  const { adapter, writes } = wireInterceptor({
    kind: "askUserQuestion",
    indices: [],
    answers: [],
    cancelled: true,
  } as UIResponse);

  feedLine(adapter, {
    type: "extension_ui_request",
    id: "ui-cancel",
    method: "select",
    title: "Pick",
    options: ["A", "B"],
  });
  await delay(10);

  assert.deepEqual(JSON.parse(writes[0]), { type: "extension_ui_response", id: "ui-cancel", cancelled: true });
});

test("regression: no askUser wired (no app / post-connector-removal) → cancel, pi never hangs", async () => {
  // After removing the makit-pi connector + HTTP bridge, ask_user relies solely
  // on the askUser callback. If none is wired, the interceptor must still reply
  // (cancelled) so pi's ctx.ui.select promise resolves instead of hanging.
  const adapter = new PiAdapter();
  (adapter as any).sessionId = "sess-none";
  // NB: askUser intentionally left undefined.
  const writes = withFakeStdin(adapter);

  feedLine(adapter, {
    type: "extension_ui_request",
    id: "ui-noapp",
    method: "select",
    title: "Pick",
    options: ["A"],
  });
  await delay(10);

  assert.deepEqual(JSON.parse(writes[0]), { type: "extension_ui_response", id: "ui-noapp", cancelled: true });
});

test("regression: interception is keyed on method, not the tool name", async () => {
  // ask_user is invisible to makit — detection switches on evt.method. A
  // never-before-seen method must cancel (not throw, not hang).
  const { adapter, calls, writes } = wireInterceptor({ kind: "input", value: "x" } as UIResponse);
  feedLine(adapter, { type: "extension_ui_request", id: "ui-unknown", method: "someFutureMethod" });
  await delay(10);
  assert.equal(calls.length, 0, "unknown method should not reach askUser");
  assert.deepEqual(JSON.parse(writes[0]), { type: "extension_ui_response", id: "ui-unknown", cancelled: true });
});

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
