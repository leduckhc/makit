import { test } from "node:test";
import assert from "node:assert/strict";
import { once } from "node:events";
import { CodexAppServerAdapter, type CodexTransport } from "./codex.js";
import type { AdapterEvent } from "./adapter.js";
import type { UICall, UIResponse } from "../uicall.js";

/**
 * A controllable fake `codex app-server`: auto-replies to the adapter's
 * requests and lets the test push notifications / server-requests in.
 */
function fakeAppServer() {
  let lineCb: (l: string) => void = () => {};
  const sent: any[] = [];
  const feed = (obj: unknown) => lineCb(JSON.stringify(obj));

  const transport: CodexTransport = {
    send: (line) => {
      const msg = JSON.parse(line);
      sent.push(msg);
      // Auto-respond to client → server requests.
      if (msg.method && msg.id !== undefined) {
        const result = respond(msg.method);
        if (result !== undefined) queueMicrotask(() => feed({ id: msg.id, result }));
      }
    },
    onLine: (cb) => {
      lineCb = cb;
    },
    onExit: () => {},
    dispose: () => {},
  };

  function respond(method: string): unknown {
    switch (method) {
      case "initialize":
        return { userAgent: "fake", codexHome: "/tmp" };
      case "thread/start":
        return { thread: { id: "th1" } };
      case "turn/start":
        return { turn: { id: "t1" } };
      case "turn/interrupt":
        return {};
      default:
        return undefined;
    }
  }

  return { transport, sent, feed };
}

async function waitFor(pred: () => boolean, ms = 1000) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (pred()) return;
    await new Promise((r) => setTimeout(r, 5));
  }
  throw new Error("timeout");
}

test("initializes, starts a thread, runs a turn, and streams a message", async () => {
  const fake = fakeAppServer();
  const adapter = new CodexAppServerAdapter({ connect: () => fake.transport });
  const events: AdapterEvent[] = [];
  const statuses: string[] = [];
  adapter.on("event", (e) => events.push(e));
  adapter.on("status", (s) => statuses.push(s));

  await adapter.start({ cwd: process.cwd(), sessionId: "m1" });
  // Handshake: initialize, initialized, thread/start were sent.
  assert.deepEqual(
    fake.sent.map((m) => m.method).filter(Boolean).slice(0, 3),
    ["initialize", "initialized", "thread/start"],
  );

  await adapter.send({ text: "hi" });
  // Server streams the assistant reply, then completes the turn.
  fake.feed({ method: "item/agentMessage/delta", params: { itemId: "m1", delta: "Hello" } });
  fake.feed({ method: "item/completed", params: { item: { type: "agentMessage", id: "m1", text: "Hello" } } });
  fake.feed({ method: "turn/completed", params: { turn: { id: "t1" } } });

  await waitFor(() => events.some((e) => e.kind === "agent.message"));
  assert.equal((events.find((e) => e.kind === "agent.message")!.payload as any).text, "Hello");
  assert.equal((events.find((e) => e.kind === "user.message")!.payload as any).text, "hi");
  assert.ok(statuses.includes("running"));
  await waitFor(() => statuses.at(-1) === "idle");
});

test("maps native requestUserInput to askUserQuestion and returns answers by question id", async () => {
  const fake = fakeAppServer();
  const asked: UICall[] = [];
  const askUser = async (call: UICall): Promise<UIResponse> => {
    asked.push(call);
    return { kind: "askUserQuestion", indices: [0], answers: ["TypeScript"] };
  };
  const adapter = new CodexAppServerAdapter({ connect: () => fake.transport });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));

  await adapter.start({ cwd: process.cwd(), sessionId: "m1", askUser });
  await adapter.send({ text: "scaffold" });

  fake.feed({
    method: "item/tool/requestUserInput",
    id: 99,
    params: {
      threadId: "th1",
      turnId: "t1",
      itemId: "q-item",
      questions: [
        {
          id: "lang",
          header: "Language",
          question: "Which language?",
          isOther: false,
          isSecret: false,
          options: [{ label: "TypeScript", description: "TS" }, { label: "Go", description: "Go" }],
        },
      ],
    },
  });

  await waitFor(() => asked.length > 0);
  assert.equal(asked[0].kind, "askUserQuestion");
  assert.equal((asked[0] as any).questions[0].question, "Which language?");

  // The adapter replies to request id 99 with answers keyed by question id.
  await waitFor(() => fake.sent.some((m) => m.id === 99 && m.result));
  const reply = fake.sent.find((m) => m.id === 99);
  assert.deepEqual(reply.result.answers, { lang: { answers: ["TypeScript"] } });

  // While the question was pending, the session was awaiting-input.
  assert.ok(
    events.some((e) => e.kind === "session.status" && (e.payload as any).status === "awaiting-input"),
  );
});

test("maps a command approval to confirmAction and replies with the decision", async () => {
  const fake = fakeAppServer();
  const askUser = async (call: UICall): Promise<UIResponse> => {
    assert.equal(call.kind, "confirmAction");
    return { kind: "confirmAction", approved: true };
  };
  const adapter = new CodexAppServerAdapter({ connect: () => fake.transport });
  await adapter.start({ cwd: process.cwd(), sessionId: "m1", askUser });
  await adapter.send({ text: "run" });

  fake.feed({
    method: "item/commandExecution/requestApproval",
    id: 42,
    params: { threadId: "th1", turnId: "t1", itemId: "c1", command: "rm -rf build", reason: null },
  });

  await waitFor(() => fake.sent.some((m) => m.id === 42 && m.result));
  assert.equal(fake.sent.find((m) => m.id === 42).result.decision, "accept");
});

test("denies a command approval when no phone is attached (fail safe)", async () => {
  const fake = fakeAppServer();
  const adapter = new CodexAppServerAdapter({ connect: () => fake.transport });
  await adapter.start({ cwd: process.cwd(), sessionId: "m1" });
  await adapter.send({ text: "run" });
  fake.feed({
    method: "item/commandExecution/requestApproval",
    id: 7,
    params: { threadId: "th1", turnId: "t1", itemId: "c1", command: "rm -rf /", reason: null },
  });
  await waitFor(() => fake.sent.some((m) => m.id === 7 && m.result));
  assert.equal(fake.sent.find((m) => m.id === 7).result.decision, "decline");
});

test("handles item/permissions/requestApproval: grants requested perms on approve, nothing on deny", async () => {
  const fake = fakeAppServer();
  let approve = true;
  const adapter = new CodexAppServerAdapter({ connect: () => fake.transport });
  await adapter.start({
    cwd: process.cwd(),
    sessionId: "m1",
    askUser: async () => ({ kind: "confirmAction", approved: approve }),
  });
  await adapter.send({ text: "go" });

  fake.feed({
    method: "item/permissions/requestApproval",
    id: 11,
    params: { threadId: "th1", turnId: "t1", itemId: "p1", cwd: "/tmp", reason: "needs network", permissions: { network: { any: true }, fileSystem: null } },
  });
  await waitFor(() => fake.sent.some((m) => m.id === 11 && m.result));
  const granted = fake.sent.find((m) => m.id === 11).result;
  assert.deepEqual(granted.permissions, { network: { any: true } }); // fileSystem:null -> omitted over JSON
  assert.equal(granted.scope, "turn");

  approve = false;
  fake.feed({
    method: "item/permissions/requestApproval",
    id: 12,
    params: { threadId: "th1", turnId: "t1", itemId: "p2", cwd: "/tmp", reason: null, permissions: { network: { any: true }, fileSystem: null } },
  });
  await waitFor(() => fake.sent.some((m) => m.id === 12 && m.result));
  assert.deepEqual(fake.sent.find((m) => m.id === 12).result.permissions, {});
});

test("handles mcpServer/elicitation/request url mode via confirmAction", async () => {
  const fake = fakeAppServer();
  const adapter = new CodexAppServerAdapter({ connect: () => fake.transport });
  await adapter.start({
    cwd: process.cwd(),
    sessionId: "m1",
    askUser: async () => ({ kind: "confirmAction", approved: true }),
  });
  await adapter.send({ text: "go" });
  fake.feed({
    method: "mcpServer/elicitation/request",
    id: 21,
    params: { threadId: "th1", turnId: "t1", serverName: "mcp", mode: "url", message: "Log in", url: "https://x", elicitationId: "e1" },
  });
  await waitFor(() => fake.sent.some((m) => m.id === 21 && m.result));
  assert.equal(fake.sent.find((m) => m.id === 21).result.action, "accept");
});

test("emits exit + exited status on kill", async () => {
  const fake = fakeAppServer();
  const adapter = new CodexAppServerAdapter({ connect: () => fake.transport });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));
  await adapter.start({ cwd: process.cwd(), sessionId: "m1" });
  const exitP = once(adapter, "exit");
  await adapter.kill();
  await exitP;
  assert.ok(events.some((e) => e.kind === "session.status" && (e.payload as any).status === "exited"));
});
