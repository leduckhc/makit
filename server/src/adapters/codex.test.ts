import { mock, test } from "node:test";
import assert from "node:assert/strict";
import { once } from "node:events";
import { CodexAppServerAdapter, defaultConnect, probeCodexConfigOptions, projectCodexModelList, buildCodexConfigOptions, projectCodexThreadList, type CodexTransport } from "./codex.js";
import type { AdapterEvent } from "./adapter.js";
import type { UICall, UIResponse } from "../uicall.js";

/**
 * A controllable fake `codex app-server`: auto-replies to the adapter's
 * requests and lets the test push notifications / server-requests in.
 */
function fakeAppServer(opts: { steer?: () => { result?: unknown; error?: unknown } } = {}) {
  let lineCb: (l: string) => void = () => {};
  const sent: any[] = [];
  const feed = (obj: unknown) => lineCb(JSON.stringify(obj));
  let turnSeq = 0;

  const transport: CodexTransport = {
    pid: undefined, // in-memory fake: no child process
    send: (line) => {
      const msg = JSON.parse(line);
      sent.push(msg);
      // Auto-respond to client → server requests.
      if (msg.method && msg.id !== undefined) {
        // `turn/steer` is scripted per-test: it is the one method whose ERROR
        // shapes are load-bearing (SPEC-35 §Evidence).
        if (msg.method === "turn/steer" && opts.steer) {
          const scripted = opts.steer();
          queueMicrotask(() => feed({ id: msg.id, ...scripted }));
          return;
        }
        const result = respond(msg.method);
        if (result !== undefined) queueMicrotask(() => feed({ id: msg.id, result }));
      }
    },
    onLine: (cb) => {
      lineCb = cb;
    },
    onExit: () => {},
    onStreamEnd: () => {},
    dispose: () => {},
  };

  function respond(method: string): unknown {
    switch (method) {
      case "initialize":
        return { userAgent: "fake", codexHome: "/tmp" };
      case "thread/start":
        return { thread: { id: "th1" } };
      case "thread/resume":
        return { thread: { id: "th-resumed" } };
      // Real codex hands back a FRESH turn id for every `turn/start`, even when
      // a turn is already in flight (in which case the message is folded into
      // the active turn and the returned id is never announced on the wire).
      case "turn/start":
        return { turn: { id: `t${++turnSeq}` } };
      case "turn/interrupt":
        return {};
      case "model/list":
        return {
          data: [
            {
              id: "gpt-5-codex",
              model: "gpt-5-codex",
              displayName: "GPT-5 Codex",
              description: "",
              hidden: false,
              supportedReasoningEfforts: [{ reasoningEffort: "medium", description: "" }],
              defaultReasoningEffort: "medium",
              serviceTiers: [{ id: "priority", name: "Fast", description: "1.5x speed, increased usage" }],
              additionalSpeedTiers: ["fast"],
              isDefault: true,
            },
            {
              id: "o3",
              model: "o3",
              displayName: "o3",
              description: "reasoning",
              hidden: false,
              supportedReasoningEfforts: [{ reasoningEffort: "high", description: "" }],
              defaultReasoningEffort: "high",
              isDefault: false,
            },
            {
              id: "hidden-model",
              model: "hidden-model",
              displayName: "Hidden",
              description: "",
              hidden: true,
              supportedReasoningEfforts: [],
              defaultReasoningEffort: "medium",
              isDefault: false,
            },
          ],
          nextCursor: null,
        };
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

test("a mid-turn send does not leave a phantom turn in flight", async () => {
  // A `turn/start` sent while a turn is active is folded by codex into the
  // active turn: the id it returns is never announced (`turn/started`) nor
  // completed. Registering it would pin the tracker to `running` forever.
  const fake = fakeAppServer();
  const adapter = new CodexAppServerAdapter({ connect: () => fake.transport });
  const statuses: string[] = [];
  adapter.on("status", (s) => statuses.push(s));
  await adapter.start({ cwd: process.cwd(), sessionId: "m1" });

  await adapter.send({ text: "long task" });
  fake.feed({ method: "turn/started", params: { turn: { id: "t1" } } });
  await waitFor(() => statuses.at(-1) === "running");

  // User types again while the agent is still working.
  await adapter.send({ text: "actually, do X instead" });
  await waitFor(() => fake.sent.filter((m) => m.method === "turn/start").length === 2);

  // Only the original turn ever completes.
  fake.feed({ method: "turn/completed", params: { turn: { id: "t1" } } });
  await waitFor(() => statuses.at(-1) === "idle");

  // And a cancel targets the announced turn, never the unannounced id.
  await adapter.send({ text: "more" });
  fake.feed({ method: "turn/started", params: { turn: { id: "t3" } } });
  await waitFor(() => statuses.at(-1) === "running");
  await adapter.cancel();
  assert.deepEqual(
    fake.sent.filter((m) => m.method === "turn/interrupt").map((m) => m.params.turnId),
    ["t3"],
  );
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
          multiSelect: true,
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
  assert.equal((asked[0] as any).questions[0].multi, true);

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

test("defaultConnect routes a spawn failure to onExit instead of crashing the daemon", async () => {
  // A missing binary makes spawn emit 'error' (not exit). With no listener that
  // is an uncaught exception; the transport must route it to onExit(null).
  const transport = defaultConnect("makit-nonexistent-binary-xyz", [])(process.cwd(), {});
  const exit = new Promise<number | null>((resolve) => transport.onExit(resolve));
  const code = await withTimeout(exit, 2000, "onExit never fired on spawn failure");
  assert.equal(code, null);
});

test("start() rejects cleanly when the codex binary is missing (no crash)", async () => {
  const adapter = new CodexAppServerAdapter({ command: "makit-nonexistent-binary-xyz" });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));
  await assert.rejects(adapter.start({ cwd: process.cwd(), sessionId: "s1" }));
  assert.ok(
    events.some((e) => e.kind === "session.status" && (e.payload as any).status === "exited"),
    "expected an exited status event after the failed spawn",
  );
});

function withTimeout<T>(p: Promise<T>, ms: number, msg: string): Promise<T> {
  return Promise.race([
    p,
    new Promise<T>((_, reject) => setTimeout(() => reject(new Error(msg)), ms).unref()),
  ]);
}

// ---- SPEC-26: codex app-server config-option projection -------------------

async function collectMeta(events: AdapterEvent[], ms = 1000): Promise<any> {
  await waitFor(() => events.some((e) => e.kind === "session.meta"), ms);
  return events.find((e) => e.kind === "session.meta")!.payload as any;
}

test("projects model/list + reasoning effort into session.meta configOptions", async () => {
  const fake = fakeAppServer();
  const adapter = new CodexAppServerAdapter({ connect: () => fake.transport });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));

  await adapter.start({ cwd: process.cwd(), sessionId: "m1" });
  const payload = await collectMeta(events);

  const byId = Object.fromEntries(payload.configOptions.map((o: any) => [o.id, o]));
  // model option — from model/list, hidden models excluded, default is current.
  assert.deepEqual(byId.model, {
    id: "model",
    name: "Model",
    category: "model",
    type: "select",
    currentValue: "gpt-5-codex",
    options: [
      { value: "gpt-5-codex", name: "GPT-5 Codex" },
      { value: "o3", name: "o3", description: "reasoning" },
    ],
  });
  // thought_level option — the ACTIVE model's advertised efforts (gpt-5-codex
  // advertises only "medium").
  assert.deepEqual(byId.thought_level, {
    id: "thought_level",
    name: "Reasoning effort",
    category: "thought_level",
    type: "select",
    currentValue: "medium",
    options: [{ value: "medium", name: "Medium" }],
  });
});

test("thought_level options follow the active model + clamp on model switch", async () => {
  const fake = fakeAppServer();
  const adapter = new CodexAppServerAdapter({ connect: () => fake.transport });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));

  await adapter.start({ cwd: process.cwd(), sessionId: "m1" });
  await collectMeta(events);

  // Switch to o3, which advertises only "high" (not the current "medium").
  events.length = 0;
  await adapter.sendAction!("configOption", { id: "model", value: "o3" });
  const payload = await collectMeta(events);
  const tl = payload.configOptions.find((o: any) => o.id === "thought_level");
  // The effort list is now o3's set, and the current effort is clamped to o3's
  // default ("high") instead of the stale "medium".
  assert.deepEqual(tl.options, [{ value: "high", name: "High" }]);
  assert.equal(tl.currentValue, "high");

  await adapter.send({ text: "go" });
  const turn = fake.sent.filter((m) => m.method === "turn/start").at(-1);
  assert.equal(turn.params.effort, "high");
});

test("Fast service tier: emitted for a fast-capable model, toggles serviceTier", async () => {
  const fake = fakeAppServer();
  const adapter = new CodexAppServerAdapter({ connect: () => fake.transport });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));

  await adapter.start({ cwd: process.cwd(), sessionId: "m1" });
  const meta = await collectMeta(events);
  const fast = meta.configOptions.find((o: any) => o.id === "fast");
  // gpt-5-codex advertises the priority/fast tier → a boolean Fast option,
  // defaulting OFF.
  assert.ok(fast, "fast option present for a fast-capable model");
  assert.equal(fast.type, "boolean");
  assert.equal(fast.category, "model_config");
  assert.equal(fast.currentValue, false);

  // OFF (default) → turn/start omits serviceTier.
  await adapter.send({ text: "a" });
  assert.equal(fake.sent.filter((m) => m.method === "turn/start").at(-1).params.serviceTier, undefined);

  // Toggle ON → turn/start sends serviceTier "priority".
  events.length = 0;
  await adapter.sendAction!("configOption", { id: "fast", value: true });
  const on = await collectMeta(events);
  assert.equal(on.configOptions.find((o: any) => o.id === "fast").currentValue, true);
  await adapter.send({ text: "b" });
  assert.equal(fake.sent.filter((m) => m.method === "turn/start").at(-1).params.serviceTier, "priority");
});

test("Fast is dropped when switching to a model that doesn't support it", async () => {
  const fake = fakeAppServer();
  const adapter = new CodexAppServerAdapter({ connect: () => fake.transport });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));

  await adapter.start({ cwd: process.cwd(), sessionId: "m1" });
  await collectMeta(events);
  await adapter.sendAction!("configOption", { id: "fast", value: true });

  // Switch to o3 (no serviceTiers) → the Fast option disappears + resets.
  events.length = 0;
  await adapter.sendAction!("configOption", { id: "model", value: "o3" });
  const meta = await collectMeta(events);
  assert.equal(meta.configOptions.find((o: any) => o.id === "fast"), undefined);
  await adapter.send({ text: "c" });
  assert.equal(fake.sent.filter((m) => m.method === "turn/start").at(-1).params.serviceTier, undefined);
});

test("configOption model action re-emits meta and overrides the next turn's model", async () => {
  const fake = fakeAppServer();
  const adapter = new CodexAppServerAdapter({ connect: () => fake.transport });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));

  await adapter.start({ cwd: process.cwd(), sessionId: "m1" });
  await collectMeta(events);

  events.length = 0;
  await adapter.sendAction!("configOption", { id: "model", value: "o3" });
  const payload = await collectMeta(events);
  assert.equal(payload.configOptions.find((o: any) => o.id === "model").currentValue, "o3");

  await adapter.send({ text: "go" });
  const turn = fake.sent.filter((m) => m.method === "turn/start").at(-1);
  assert.equal(turn.params.model, "o3");
});

test("configOption thought_level action overrides the next turn's reasoning effort", async () => {
  const fake = fakeAppServer();
  const adapter = new CodexAppServerAdapter({ connect: () => fake.transport });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));

  await adapter.start({ cwd: process.cwd(), sessionId: "m1" });
  await collectMeta(events);
  await adapter.sendAction!("configOption", { id: "thought_level", value: "high" });
  await adapter.send({ text: "go" });
  const turn = fake.sent.filter((m) => m.method === "turn/start").at(-1);
  assert.equal(turn.params.effort, "high");
});

// ---------- capability projection + probe (SPEC-27) ------------------------

test("a forced non-default model initialises effort from that model", async () => {
  const fake = fakeAppServer();
  // Force o3 (non-default); o3 advertises only "high" (default model gpt-5-codex
  // advertises "medium"). The effort must follow o3, not the catalog default.
  const adapter = new CodexAppServerAdapter({ connect: () => fake.transport, model: "o3" });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));

  await adapter.start({ cwd: process.cwd(), sessionId: "m1" });
  const payload = await collectMeta(events);
  const tl = payload.configOptions.find((o: any) => o.id === "thought_level");
  assert.equal(tl.currentValue, "high");
  assert.deepEqual(tl.options, [{ value: "high", name: "High" }]);

  await adapter.send({ text: "go" });
  const turn = fake.sent.filter((m) => m.method === "turn/start").at(-1);
  assert.equal(turn.params.effort, "high");
});

test("projectCodexModelList maps visible models and picks the default", () => {
  const projected = projectCodexModelList({
    data: [
      { model: "gpt-5-codex", displayName: "GPT-5 Codex", hidden: false, defaultReasoningEffort: "medium", isDefault: true },
      { model: "o3", displayName: "o3", description: "reasoning", hidden: false, isDefault: false },
      { model: "hidden-model", hidden: true },
    ],
  });
  assert.deepEqual(
    projected.models.map((m) => m.value),
    ["gpt-5-codex", "o3"],
  );
  assert.equal(projected.activeModel, "gpt-5-codex");
  assert.equal(projected.activeEffort, "medium");
});

test("buildCodexConfigOptions emits model + thought_level, defaulting effort", () => {
  const options = buildCodexConfigOptions([{ value: "o3", name: "o3" }], "o3", undefined);
  assert.equal(options[0].id, "model");
  assert.equal(options[0].currentValue, "o3");
  assert.equal(options[1].id, "thought_level");
  assert.equal(options[1].currentValue, "medium");
});

test("buildCodexConfigOptions omits the model option when the catalog is empty", () => {
  const options = buildCodexConfigOptions([], undefined, "high");
  assert.equal(options.length, 1);
  assert.equal(options[0].id, "thought_level");
  assert.equal(options[0].currentValue, "high");
});

test("probeCodexConfigOptions projects the app-server model/list surface (no thread started)", async () => {
  const fake = fakeAppServer();
  const options = await probeCodexConfigOptions({ connect: () => fake.transport });
  // Handshake used initialize + model/list, but NEVER thread/start.
  const methods = fake.sent.map((m: any) => m.method).filter(Boolean);
  assert.ok(methods.includes("initialize"));
  assert.ok(methods.includes("model/list"));
  assert.ok(!methods.includes("thread/start"), "probe must not start a thread");
  // Projected into the shared config-option shape.
  const model = options.find((o) => o.id === "model");
  assert.ok(model);
  assert.deepEqual(model!.options!.map((m) => m.value), ["gpt-5-codex", "o3"]);
  assert.ok(options.some((o) => o.id === "thought_level"));
});

test("projectCodexThreadList filters by cwd, drops ephemeral, scales seconds→ms (SPEC-29)", () => {
  const res = {
    data: [
      { id: "t1", cwd: "/repo", preview: "hi", recencyAt: 1700000000, ephemeral: false },
      { id: "t2", cwd: "/other", preview: "nope", recencyAt: 1700000100 },
      { id: "t3", cwd: "/repo", preview: "ghost", ephemeral: true },
      { id: "t4", cwd: "/repo", updatedAt: 1700000200 },
    ],
  };
  const out = projectCodexThreadList(res, "/repo");
  assert.deepEqual(out.map((t) => t.id), ["t1", "t4"]);
  assert.equal(out[0].preview, "hi");
  assert.equal(out[0].updatedAt, 1700000000 * 1000);
  assert.equal(out[1].updatedAt, 1700000200 * 1000);
});

test("projectCodexThreadList tolerates a malformed result", () => {
  assert.deepEqual(projectCodexThreadList(null, "/repo"), []);
  assert.deepEqual(projectCodexThreadList({ data: "nope" }, "/repo"), []);
});

test("start({resumeAgentSessionId}) resumes via thread/resume, not thread/start (SPEC-29)", async () => {
  const fake = fakeAppServer();
  const adapter = new CodexAppServerAdapter({ connect: () => fake.transport });
  await adapter.start({ cwd: "/repo", sessionId: "m1", resumeAgentSessionId: "th-prev" });
  const methods = fake.sent.map((m: any) => m.method).filter(Boolean);
  assert.ok(methods.includes("thread/resume"), "must call thread/resume");
  assert.ok(!methods.includes("thread/start"), "must NOT start a fresh thread");
  const resume = fake.sent.find((m: any) => m.method === "thread/resume");
  assert.equal(resume.params.threadId, "th-prev");
  assert.equal(resume.params.cwd, "/repo");
  assert.equal(adapter.agentSessionId, "th-resumed");
  await adapter.kill();
});

test("codex advertises the full session lifecycle capability set (SPEC-29)", () => {
  const adapter = new CodexAppServerAdapter();
  assert.deepEqual(adapter.capabilities, { resume: true, load: false, list: true, delete: true, fork: true, archive: true });
});

/**
 * SPEC-35 T2 — `turn/steer`. Ids and error strings are verbatim from the live
 * spike against codex-cli 0.146.0 (spec §Evidence), so a protocol change shows
 * up here as a failure rather than as a silently-queued message in production.
 */
async function steerHarness(steer: () => { result?: unknown; error?: unknown }) {
  const fake = fakeAppServer({ steer });
  const adapter = new CodexAppServerAdapter({ connect: () => fake.transport });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));
  await adapter.start({ cwd: process.cwd(), sessionId: "m1" });
  await adapter.send({ text: "long task" });
  fake.feed({ method: "turn/started", params: { turn: { id: "t1" } } });
  await waitFor(() => fake.sent.some((m) => m.method === "turn/start"));
  const echoesBefore = events.filter((e) => e.kind === "user.message").length;
  return { fake, adapter, events, echoesBefore };
}

test("steer(): accepted — injects into the active turn and echoes once", async () => {
  const h = await steerHarness(() => ({ result: { turnId: "t1" } }));

  assert.equal(await h.adapter.steer({ text: "do X instead" }), true);

  const steers = h.fake.sent.filter((m) => m.method === "turn/steer");
  assert.equal(steers.length, 1);
  assert.equal(steers[0].params.threadId, "th1");
  assert.equal(steers[0].params.expectedTurnId, "t1", "precondition = the ANNOUNCED turn id");
  assert.deepEqual(steers[0].params.input, [{ type: "text", text: "do X instead", text_elements: [] }]);
  assert.equal(
    h.fake.sent.filter((m) => m.method === "turn/start").length,
    1,
    "steering must never start a second turn",
  );
  const echo = h.events.filter((e) => e.kind === "user.message").at(-1)!;
  assert.equal(h.events.filter((e) => e.kind === "user.message").length, h.echoesBefore + 1);
  assert.equal(
    (echo.payload as { steered?: boolean }).steered,
    true,
    "a steered message is flagged so the app can say so on the bubble",
  );
});

test("a normal turn's echo is not flagged as steered", async () => {
  const fake = fakeAppServer();
  const adapter = new CodexAppServerAdapter({ connect: () => fake.transport });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));
  await adapter.start({ cwd: process.cwd(), sessionId: "m1" });

  await adapter.send({ text: "hi" });

  const echo = events.find((e) => e.kind === "user.message")!;
  assert.equal((echo.payload as { steered?: boolean }).steered, undefined);
});

// Error objects verbatim from live codex (spec §Evidence). `activeTurnNotSteerable`
// lives in `data.codexErrorInfo` — NOT in `message` — which is exactly why the
// ladder keys off "the request rejected" rather than off string matching.
for (const [label, error] of [
  ["no active turn", { code: -32600, message: "no active turn to steer" }],
  [
    "stale precondition",
    {
      code: -32600,
      message: "expected active turn id `t0` but found `t1`",
    },
  ],
  [
    "non-steerable compact turn",
    {
      code: -32600,
      message: "cannot steer a compact turn",
      data: {
        message: "cannot steer a compact turn",
        codexErrorInfo: { activeTurnNotSteerable: { turnKind: "compact" } },
        additionalDetails: null,
      },
    },
  ],
  [
    "non-steerable review turn",
    {
      code: -32600,
      message: "cannot steer a review turn",
      data: {
        message: "cannot steer a review turn",
        codexErrorInfo: { activeTurnNotSteerable: { turnKind: "review" } },
        additionalDetails: null,
      },
    },
  ],
] as const) {
  test(`steer(): ${label} — reports false and echoes nothing`, async () => {
    const h = await steerHarness(() => ({ error }));

    assert.equal(await h.adapter.steer({ text: "do X instead" }), false);
    assert.equal(
      h.events.filter((e) => e.kind === "user.message").length,
      h.echoesBefore,
      "a message that was not delivered must not appear in the transcript",
    );
    assert.equal(
      h.events.filter((e) => e.kind === "session.error").length,
      0,
      "a queueable steer failure is not a session error",
    );
    assert.equal(h.fake.sent.filter((m) => m.method === "turn/start").length, 1);
  });
}

test("a cua-driver screenshot in an MCP tool result lands in the media store", async () => {
  const fake = fakeAppServer();
  const puts: { data: string; mime: string }[] = [];
  const adapter = new CodexAppServerAdapter({
    connect: () => fake.transport,
    media: {
      putBase64: (data: string, mime: string) => {
        puts.push({ data, mime });
        return { mediaId: "med1", mime, sizeBytes: data.length };
      },
    } as any,
  });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));
  await adapter.start({ cwd: process.cwd(), sessionId: "m-cu" });

  fake.feed({
    method: "item/completed",
    params: {
      item: {
        type: "mcpToolCall",
        id: "cu1",
        server: "cua_driver",
        tool: "computer_use",
        arguments: { action: "capture", mode: "som" },
        result: {
          content: [
            { type: "text", text: "12 elements" },
            { type: "image", data: "UE5H", mimeType: "image/png" },
          ],
        },
      },
    },
  });
  await waitFor(() => events.some((e) => e.kind === "agent.media"));

  assert.deepEqual(puts, [{ data: "UE5H", mime: "image/png" }]);
  const media = events.find((e) => e.kind === "agent.media")!;
  assert.equal((media.payload as any).mediaId, "med1");
  assert.equal((media.payload as any).callId, "cu1");
  // The tool row still renders its name + text output.
  const start = events.find((e) => e.kind === "tool.call.start")!;
  assert.equal((start.payload as any).name, "cua_driver/computer_use");
  assert.equal((events.find((e) => e.kind === "tool.call.end")!.payload as any).output, "12 elements");
  await adapter.kill();
});

test("a timed-out request cleans up its pending entry (and a normal one its timer)", async () => {
  const fake = fakeAppServer();
  const adapter = new CodexAppServerAdapter({ connect: () => fake.transport });
  await adapter.start({ cwd: process.cwd(), sessionId: "m-leak" });
  const pending = (adapter as unknown as { pending: Map<number, unknown> }).pending;
  const before = pending.size;

  // A request nothing will ever answer, with a timeout short enough to test.
  const req = (
    adapter as unknown as {
      request: (m: string, p: unknown, t?: number) => Promise<unknown>;
    }
  ).request("thread/never", {}, 20);
  assert.equal(pending.size, before + 1, "the request is tracked while in flight");
  await assert.rejects(req, /timeout after 20ms/);
  assert.equal(
    pending.size,
    before,
    "a timed-out request must not leave its entry behind — repeated timeouts grew the map forever",
  );

  // And the happy path leaves nothing tracked either — `thread/start` is one the
  // fake answers, so this exercises the resolve side.
  await (
    adapter as unknown as { request: (m: string, p: unknown, t?: number) => Promise<unknown> }
  ).request("thread/start", {}, 5_000);
  assert.equal(pending.size, before, "a resolved request clears its entry (and its timer)");
  await adapter.kill();
});

test("steer(): a TIMED-OUT steer still echoes, so the message is not lost silently", async () => {
  // The timeout is ambiguous — codex may have folded the message into the turn or
  // dropped it — and `steer` returns true either way so the session does not
  // re-queue and duplicate it. Without an echo, that ambiguity cost the user their
  // message with no trace at all.
  //
  // Mocked timers, because the adapter's own timeout is 15s: `steer` is scripted
  // to never answer, then the clock is driven past the deadline.
  // An empty scripted reply: the fake writes `{ id }` with neither `result` nor
  // `error`, which `handleLine` ignores — so the request never settles and the
  // adapter's own timeout is the only way out.
  const fake = fakeAppServer({ steer: () => ({}) });
  const adapter = new CodexAppServerAdapter({ connect: () => fake.transport });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));
  await adapter.start({ cwd: process.cwd(), sessionId: "m-timeout" });
  await adapter.send({ text: "long task" });
  fake.feed({ method: "turn/started", params: { turn: { id: "t1" } } });
  await waitFor(() => fake.sent.some((m) => m.method === "turn/start"));
  const before = events.filter((e) => e.kind === "user.message").length;

  mock.timers.enable({ apis: ["setTimeout"] });
  try {
    const steered = (adapter as unknown as { steer: (i: { text: string }) => Promise<boolean> }).steer({
      text: "do X instead",
    });
    mock.timers.tick(15_001);
    assert.equal(await steered, true, "a timed-out steer must not be re-queued");
  } finally {
    mock.timers.reset();
  }

  const echoes = events.filter((e) => e.kind === "user.message");
  assert.equal(
    echoes.length,
    before + 1,
    "the message must be visible even when the steer's fate is unknown",
  );
  assert.equal((echoes.at(-1)!.payload as { steered?: boolean }).steered, true);
  await adapter.kill();
});
