import { test } from "node:test";
import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtempSync, rmSync, symlinkSync, writeFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  AgentSideConnection,
  ndJsonStream,
  type Agent,
  type AgentSideConnection as AgentConn,
  type InitializeRequest,
  type NewSessionRequest,
  type PromptRequest,
  type PromptResponse,
} from "@agentclientprotocol/sdk";
import { AcpAdapter, defaultConnect, probeAcpConfigOptions, listAcpSessions, deriveAcpCapabilities, type AcpTransport } from "./acp.js";
import type { AdapterEvent } from "./adapter.js";
import type { UICall, UIResponse } from "../uicall.js";
import { MediaStore } from "../media/store.js";

/**
 * Build a paired in-memory transport: makit's AcpAdapter (client) on one end,
 * a caller-supplied fake Agent on the other. No subprocess.
 */
function pair(makeAgent: (conn: AgentConn) => Agent): { transport: AcpTransport; agent: AgentSideConnection } {
  const c2a = new TransformStream<Uint8Array, Uint8Array>();
  const a2c = new TransformStream<Uint8Array, Uint8Array>();
  const clientStream = ndJsonStream(c2a.writable, a2c.readable);
  const agentStream = ndJsonStream(a2c.writable, c2a.readable);
  const agent = new AgentSideConnection(makeAgent, agentStream);
  const transport: AcpTransport = {
    stream: clientStream,
    onExit: () => {},
    dispose: () => {},
  };
  return { transport, agent };
}

/** A minimal ACP agent that emits scripted updates for each prompt. */
class ScriptedAgent implements Agent {
  constructor(
    private readonly conn: AgentConn,
    private readonly script: (sessionId: string, text: string) => Promise<void>,
  ) {}
  async initialize(_p: InitializeRequest) {
    return {
      protocolVersion: 1 as const,
      agentCapabilities: { loadSession: false },
    };
  }
  async newSession(_p: NewSessionRequest) {
    return { sessionId: "acp-sess-1" };
  }
  async authenticate() {
    return;
  }
  async prompt(p: PromptRequest): Promise<PromptResponse> {
    const text = p.prompt.map((b) => (b.type === "text" ? b.text : "")).join("");
    await this.script(p.sessionId, text);
    return { stopReason: "end_turn" };
  }
  async cancel() {
    return;
  }

  update(sessionId: string, update: unknown) {
    return this.conn.sessionUpdate({ sessionId, update: update as any });
  }
}

async function collectUntil(events: AdapterEvent[], kind: string, timeoutMs = 1000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (events.some((e) => e.kind === kind)) return;
    await new Promise((r) => setTimeout(r, 5));
  }
  throw new Error(`timeout waiting for ${kind}; got: ${events.map((e) => e.kind).join(",")}`);
}

test("emits session.meta from ACP modes and maps the mode action to set_session_mode", async () => {
  const setModeCalls: { sessionId: string; modeId: string }[] = [];
  let agentRef: ScriptedAgent;
  const { transport } = pair((conn) => {
    agentRef = new ScriptedAgent(conn, async () => {});
    // Advertise modes on session creation and record set_session_mode calls.
    (agentRef as unknown as {
      newSession: () => Promise<unknown>;
      setSessionMode: (p: { sessionId: string; modeId: string }) => Promise<unknown>;
    }).newSession = async () => ({
      sessionId: "acp-sess-1",
      modes: {
        currentModeId: "code",
        availableModes: [
          { id: "ask", name: "Ask" },
          { id: "code", name: "Code" },
        ],
      },
    });
    (agentRef as unknown as {
      setSessionMode: (p: { sessionId: string; modeId: string }) => Promise<unknown>;
    }).setSessionMode = async (p) => {
      setModeCalls.push(p);
      return {};
    };
    return agentRef;
  });

  const adapter = new AcpAdapter({ spec: { agent: "codex", command: "x" }, connect: () => transport });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));

  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1" });
  await collectUntil(events, "session.meta");

  const meta = events.find((e) => e.kind === "session.meta");
  const payload = meta!.payload as any;
  assert.equal(payload.modes.current, "code");
  assert.equal(payload.modes.available.length, 2);
  assert.equal(payload.modes.available[1].name, "Code");
  // ACP has no model/thinking.
  assert.equal(payload.model, null);
  assert.equal(payload.thinking, "");

  // The mode action reaches the agent as set_session_mode and re-emits meta.
  events.length = 0;
  await adapter.sendAction!("mode", { id: "ask" });
  assert.deepEqual(setModeCalls.at(-1), { sessionId: "acp-sess-1", modeId: "ask" });
  await collectUntil(events, "session.meta");
  assert.equal((events.find((e) => e.kind === "session.meta")!.payload as any).modes.current, "ask");
});

test("agent-initiated current_mode_update re-emits session.meta with the new mode", async () => {
  let agentRef: ScriptedAgent;
  const { transport } = pair((conn) => {
    agentRef = new ScriptedAgent(conn, async () => {});
    (agentRef as unknown as { newSession: () => Promise<unknown> }).newSession = async () => ({
      sessionId: "acp-sess-1",
      modes: {
        currentModeId: "code",
        availableModes: [
          { id: "ask", name: "Ask" },
          { id: "code", name: "Code" },
        ],
      },
    });
    return agentRef;
  });

  const adapter = new AcpAdapter({ spec: { agent: "codex", command: "x" }, connect: () => transport });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));

  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1" });
  await collectUntil(events, "session.meta");
  assert.equal((events.find((e) => e.kind === "session.meta")!.payload as any).modes.current, "code");

  // The agent switches modes autonomously → a current_mode_update notification
  // (per ACP's CurrentModeUpdate, the field is `currentModeId`) must re-emit
  // session.meta with the new current mode.
  events.length = 0;
  await agentRef!.update("acp-sess-1", { sessionUpdate: "current_mode_update", currentModeId: "ask" });
  await collectUntil(events, "session.meta");
  assert.equal((events.find((e) => e.kind === "session.meta")!.payload as any).modes.current, "ask");
});

test("initializes, prompts, and streams a full turn end-to-end", async () => {
  let agentRef: ScriptedAgent;
  const { transport } = pair((conn) => {
    agentRef = new ScriptedAgent(conn, async (sessionId) => {
      await agentRef.update(sessionId, {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "Hi " },
      });
      await agentRef.update(sessionId, {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "there" },
      });
    });
    return agentRef;
  });

  const adapter = new AcpAdapter({ spec: { agent: "pi", command: "x" }, connect: () => transport });
  const events: AdapterEvent[] = [];
  const statuses: string[] = [];
  adapter.on("event", (e) => events.push(e));
  adapter.on("status", (s) => statuses.push(s));

  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1" });
  await adapter.send({ text: "hello" });
  await collectUntil(events, "agent.message");

  const user = events.find((e) => e.kind === "user.message");
  assert.equal((user!.payload as { text: string }).text, "hello");

  const finalMsg = events.find((e) => e.kind === "agent.message");
  assert.equal((finalMsg!.payload as { text: string }).text, "Hi there");

  assert.ok(statuses.includes("running"));
  assert.equal(statuses.at(-1), "idle");
});

test("routes a permission request to askUser and honors approval", async () => {
  let agentRef: ScriptedAgent;
  let permissionResolved: string | undefined;
  const { transport } = pair((conn) => {
    agentRef = new ScriptedAgent(conn, async (sessionId) => {
      const res = await conn.requestPermission({
        sessionId,
        toolCall: { toolCallId: "t1", title: "rm -rf build", kind: "delete", status: "pending" },
        options: [
          { optionId: "ok", name: "Allow", kind: "allow_once" },
          { optionId: "nope", name: "Deny", kind: "reject_once" },
        ],
      });
      permissionResolved = res.outcome.outcome === "selected" ? res.outcome.optionId : "cancelled";
    });
    return agentRef;
  });

  const asked: UICall[] = [];
  const askUser = async (call: UICall): Promise<UIResponse> => {
    asked.push(call);
    return { kind: "confirmAction", approved: true };
  };

  const adapter = new AcpAdapter({ spec: { agent: "pi", command: "x" }, connect: () => transport });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));

  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1", askUser });
  await adapter.send({ text: "please delete" });

  const deadline = Date.now() + 1000;
  while (Date.now() < deadline && permissionResolved === undefined) {
    await new Promise((r) => setTimeout(r, 5));
  }

  assert.equal(asked.length, 1);
  assert.equal(asked[0].kind, "confirmAction");
  assert.equal(permissionResolved, "ok");
});

test("routes a multiple-choice select to an inline askUserQuestion", async () => {
  let agentRef: ScriptedAgent;
  let selectedOptionId: string | undefined;
  const { transport } = pair((conn) => {
    agentRef = new ScriptedAgent(conn, async (sessionId) => {
      // pi-acp surfaces `ctx.ui.select` as a permission whose options ARE the
      // choices (all allow_once, no reject), with the question in rawInput.
      const res = await conn.requestPermission({
        sessionId,
        toolCall: {
          toolCallId: "pi-ui-1",
          title: "Pick a branch",
          kind: "other",
          status: "pending",
          rawInput: { method: "select", title: "Pick a branch", message: "Which branch?" },
        } as any,
        options: [
          { optionId: "choice-0", name: "main", kind: "allow_once" },
          { optionId: "choice-1", name: "develop", kind: "allow_once" },
          { optionId: "choice-2", name: "release", kind: "allow_once" },
        ],
      });
      selectedOptionId = res.outcome.outcome === "selected" ? res.outcome.optionId : "cancelled";
    });
    return agentRef;
  });

  const asked: UICall[] = [];
  const askUser = async (call: UICall): Promise<UIResponse> => {
    asked.push(call);
    // User picks the second option ("develop").
    return { kind: "askUserQuestion", indices: [1], answers: ["develop"], answer: "develop" };
  };

  const adapter = new AcpAdapter({ spec: { agent: "pi", command: "x" }, connect: () => transport });
  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1", askUser });
  await adapter.send({ text: "choose" });

  const deadline = Date.now() + 1000;
  while (Date.now() < deadline && selectedOptionId === undefined) {
    await new Promise((r) => setTimeout(r, 5));
  }

  assert.equal(asked.length, 1);
  assert.equal(asked[0].kind, "askUserQuestion");
  const q = (asked[0] as any).questions[0];
  assert.equal(q.question, "Which branch?");
  assert.deepEqual(q.options.map((o: any) => o.label), ["main", "develop", "release"]);
  // The chosen label maps back to its optionId.
  assert.equal(selectedOptionId, "choice-1");
});

test("select maps the chosen option by index, not label (labels can collide)", async () => {
  let agentRef: ScriptedAgent;
  let selectedOptionId: string | undefined;
  const { transport } = pair((conn) => {
    agentRef = new ScriptedAgent(conn, async (sessionId) => {
      const res = await conn.requestPermission({
        sessionId,
        toolCall: {
          toolCallId: "pi-ui-2",
          title: "Overwrite?",
          kind: "other",
          status: "pending",
          rawInput: { method: "select", title: "Overwrite?" },
        } as any,
        // Two options share the SAME label but map to different optionIds.
        options: [
          { optionId: "opt-a", name: "Keep", kind: "allow_once" },
          { optionId: "opt-b", name: "Keep", kind: "allow_once" },
        ],
      });
      selectedOptionId = res.outcome.outcome === "selected" ? res.outcome.optionId : "cancelled";
    });
    return agentRef;
  });

  const askUser = async (): Promise<UIResponse> =>
    // User picked the SECOND "Keep" (index 1).
    ({ kind: "askUserQuestion", indices: [1], answers: ["Keep"], answer: "Keep" });

  const adapter = new AcpAdapter({ spec: { agent: "pi", command: "x" }, connect: () => transport });
  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1", askUser });
  await adapter.send({ text: "choose" });

  const deadline = Date.now() + 1000;
  while (Date.now() < deadline && selectedOptionId === undefined) {
    await new Promise((r) => setTimeout(r, 5));
  }
  // Index-based mapping must pick opt-b; a label match would wrongly pick opt-a.
  assert.equal(selectedOptionId, "opt-b");
});

test("select recovers option descriptions from the in-flight ask_user tool args", async () => {
  let agentRef: ScriptedAgent;
  const { transport } = pair((conn) => {
    agentRef = new ScriptedAgent(conn, async (sessionId) => {
      // pi-ask-user's headless fallback calls `ctx.ui.select(prompt, titles)`,
      // so the permission options are title-only strings — the descriptions
      // only exist on the concurrently-running `ask_user` tool call's args.
      await conn.sessionUpdate({
        sessionId,
        update: {
          sessionUpdate: "tool_call",
          toolCallId: "tooluse_ask",
          title: "ask_user",
          kind: "other",
          status: "in_progress",
          rawInput: {
            question: "Which skill?",
            options: [
              { title: "Piano", description: "Improvise jazz" },
              { title: "Languages", description: "Converse naturally" },
            ],
          },
        } as any,
      });
      await conn.requestPermission({
        sessionId,
        toolCall: {
          toolCallId: "pi-ui-4",
          title: "Which skill?",
          kind: "other",
          status: "pending",
          rawInput: { method: "select", title: "Which skill?", options: ["Piano", "Languages", "✏️ Type custom response..."] },
        } as any,
        options: [
          { optionId: "choice-0", name: "Piano", kind: "allow_once" },
          { optionId: "choice-1", name: "Languages", kind: "allow_once" },
          { optionId: "choice-2", name: "✏️ Type custom response...", kind: "allow_once" },
        ],
      });
    });
    return agentRef;
  });

  const asked: UICall[] = [];
  const askUser = async (call: UICall): Promise<UIResponse> => {
    asked.push(call);
    return { kind: "askUserQuestion", indices: [0], answers: ["Piano"], answer: "Piano" };
  };

  const adapter = new AcpAdapter({ spec: { agent: "pi", command: "x" }, connect: () => transport });
  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1", askUser });
  await adapter.send({ text: "choose" });

  const deadline = Date.now() + 1000;
  while (Date.now() < deadline && asked.length === 0) {
    await new Promise((r) => setTimeout(r, 5));
  }

  const q = (asked[0] as any).questions[0];
  assert.deepEqual(q.options, [
    { label: "Piano", description: "Improvise jazz" },
    { label: "Languages", description: "Converse naturally" },
    // The freeform sentinel has no matching ask_user option — no description.
    { label: "✏️ Type custom response..." },
  ]);
});

test("select trims the question and drops a header that only differs by whitespace", async () => {
  let agentRef: ScriptedAgent;
  const { transport } = pair((conn) => {
    agentRef = new ScriptedAgent(conn, async (sessionId) => {
      await conn.requestPermission({
        sessionId,
        toolCall: {
          toolCallId: "pi-ui-3",
          title: "Pick one",
          kind: "other",
          status: "pending",
          // title and message are the same text but differ only by whitespace.
          rawInput: { method: "select", title: "Pick one", message: "Pick one  " },
        } as any,
        options: [
          { optionId: "choice-0", name: "a", kind: "allow_once" },
          { optionId: "choice-1", name: "b", kind: "allow_once" },
        ],
      });
    });
    return agentRef;
  });

  const asked: UICall[] = [];
  const askUser = async (call: UICall): Promise<UIResponse> => {
    asked.push(call);
    return { kind: "askUserQuestion", indices: [0], answers: ["a"], answer: "a" };
  };

  const adapter = new AcpAdapter({ spec: { agent: "pi", command: "x" }, connect: () => transport });
  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1", askUser });
  await adapter.send({ text: "choose" });

  const deadline = Date.now() + 1000;
  while (Date.now() < deadline && asked.length === 0) {
    await new Promise((r) => setTimeout(r, 5));
  }

  const q = (asked[0] as any).questions[0];
  assert.equal(q.question, "Pick one"); // trimmed
  assert.equal(q.header, undefined); // no redundant header for a whitespace-only diff
});

test("routes a pi ctx.ui.confirm (allow+reject) to an inline askUserQuestion", async () => {
  let agentRef: ScriptedAgent;
  let selectedOptionId: string | undefined;
  const { transport } = pair((conn) => {
    agentRef = new ScriptedAgent(conn, async (sessionId) => {
      // pi-acp surfaces ctx.ui.confirm as a pi-ui permission with a reject option.
      const res = await conn.requestPermission({
        sessionId,
        toolCall: {
          toolCallId: "pi-ui-confirm-1",
          title: "Proceed?",
          kind: "other",
          status: "pending",
          rawInput: { method: "confirm", title: "Proceed?" },
        } as any,
        options: [
          { optionId: "yes", name: "Yes", kind: "allow_once" },
          { optionId: "no", name: "No", kind: "reject_once" },
        ],
      });
      selectedOptionId = res.outcome.outcome === "selected" ? res.outcome.optionId : "cancelled";
    });
    return agentRef;
  });

  const asked: UICall[] = [];
  const askUser = async (call: UICall): Promise<UIResponse> => {
    asked.push(call);
    // User picks "No" (index 1) — the reject option, presented as a normal choice.
    return { kind: "askUserQuestion", indices: [1], answers: ["No"], answer: "No" };
  };

  const adapter = new AcpAdapter({ spec: { agent: "pi", command: "x" }, connect: () => transport });
  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1", askUser });
  await adapter.send({ text: "confirm" });

  const deadline = Date.now() + 1000;
  while (Date.now() < deadline && selectedOptionId === undefined) {
    await new Promise((r) => setTimeout(r, 5));
  }

  assert.equal(asked.length, 1);
  assert.equal(asked[0].kind, "askUserQuestion");
  // Both Yes AND No are offered as inline options (not a modal approve/deny).
  assert.deepEqual((asked[0] as any).questions[0].options.map((o: any) => o.label), ["Yes", "No"]);
  assert.equal(selectedOptionId, "no");
});

test("exposes an ACP permission as awaiting-approval status + rich confirmAction payload", async () => {
  let agentRef: ScriptedAgent;
  const { transport } = pair((conn) => {
    agentRef = new ScriptedAgent(conn, async (sessionId) => {
      await conn.requestPermission({
        sessionId,
        toolCall: {
          toolCallId: "t1",
          title: "rm -rf build",
          kind: "execute",
          status: "pending",
          rawInput: { command: "rm -rf build" },
        },
        options: [
          { optionId: "ok", name: "Allow", kind: "allow_once" },
          { optionId: "nope", name: "Deny", kind: "reject_once" },
        ],
      });
    });
    return agentRef;
  });

  const asked: UICall[] = [];
  const askUser = async (call: UICall): Promise<UIResponse> => {
    asked.push(call);
    return { kind: "confirmAction", approved: true };
  };

  const adapter = new AcpAdapter({ spec: { agent: "pi", command: "x" }, connect: () => transport });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));

  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1", askUser });
  await adapter.send({ text: "delete it" });
  await collectUntil(events, "session.status");

  // The permission surfaced as awaiting-approval status.
  const approvalStatus = events.find(
    (e) => e.kind === "session.status" && (e.payload as any).status === "awaiting-approval",
  );
  assert.ok(approvalStatus, "expected an awaiting-approval status event");

  // The confirmAction payload carries the tool title + a command preview.
  assert.equal(asked.length, 1);
  const call = asked[0] as any;
  assert.equal(call.kind, "confirmAction");
  assert.equal(call.action, "execute");
  assert.match(String(call.message), /rm -rf build/);
  assert.match(String(call.preview), /rm -rf build/);
});

test("denies permission when no phone is attached (fail safe)", async () => {
  let agentRef: ScriptedAgent;
  let picked: string | undefined;
  const { transport } = pair((conn) => {
    agentRef = new ScriptedAgent(conn, async (sessionId) => {
      const res = await conn.requestPermission({
        sessionId,
        toolCall: { toolCallId: "t1", title: "bash", kind: "execute", status: "pending" },
        options: [
          { optionId: "ok", name: "Allow", kind: "allow_once" },
          { optionId: "nope", name: "Deny", kind: "reject_once" },
        ],
      });
      picked = res.outcome.outcome === "selected" ? res.outcome.optionId : "cancelled";
    });
    return agentRef;
  });

  const adapter = new AcpAdapter({ spec: { agent: "pi", command: "x" }, connect: () => transport });
  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1" });
  await adapter.send({ text: "run it" });

  const deadline = Date.now() + 1000;
  while (Date.now() < deadline && picked === undefined) {
    await new Promise((r) => setTimeout(r, 5));
  }
  assert.equal(picked, "nope");
});

test("limits ACP filesystem requests to the session workspace", async () => {
  // Canonicalize like the adapter does: a real agent receives the realpath'd
  // cwd via newSession and references files under it, so the test must too.
  const cwd = realpathSync(mkdtempSync(join(tmpdir(), "makit-acp-workspace-")));
  const outside = realpathSync(tmpdir()) + `/makit-acp-outside-${Date.now()}.txt`;
  writeFileSync(join(cwd, "inside.txt"), "allowed");
  writeFileSync(outside, "private");
  symlinkSync(outside, join(cwd, "escape"));
  try {
    let doneResolve!: () => void;
    let doneReject!: (error: unknown) => void;
    const done = new Promise<void>((resolve, reject) => {
      doneResolve = resolve;
      doneReject = reject;
    });
    const { transport } = pair((conn) =>
      new ScriptedAgent(conn, async () => {
        try {
          const inside = await conn.readTextFile({ sessionId: "acp-sess-1", path: join(cwd, "inside.txt") });
          assert.equal(inside.content, "allowed");
          await assert.rejects(
            conn.readTextFile({ sessionId: "acp-sess-1", path: outside }),
          );
          await assert.rejects(
            conn.writeTextFile({ sessionId: "acp-sess-1", path: outside, content: "overwritten" }),
          );
          await assert.rejects(
            conn.readTextFile({ sessionId: "acp-sess-1", path: join(cwd, "escape") }),
          );
          doneResolve();
        } catch (error) {
          doneReject(error);
          throw error;
        }
      }),
    );
    const adapter = new AcpAdapter({ spec: { agent: "codex", command: "x" }, connect: () => transport });
    await adapter.start({ cwd, sessionId: "makit-1" });
    await adapter.send({ text: "read files" });
    await done;
  } finally {
    rmSync(cwd, { recursive: true, force: true });
    rmSync(outside, { force: true });
  }
});

test("elicitation url mode → confirmAction with the URL, accept on approve", async () => {
  let outcome: string | undefined;
  const { transport } = pair((conn) => {
    const a = new ScriptedAgent(conn, async (sessionId) => {
      const res = await conn.unstable_createElicitation({
        mode: "url",
        sessionId,
        message: "Sign in to continue",
        elicitationId: "e1",
        url: "https://auth.example.com/login",
      } as any);
      outcome = (res as any).action;
    });
    return a;
  });

  const asked: UICall[] = [];
  const askUser = async (call: UICall): Promise<UIResponse> => {
    asked.push(call);
    return { kind: "confirmAction", approved: true };
  };

  const adapter = new AcpAdapter({ spec: { agent: "pi", command: "x" }, connect: () => transport });
  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1", askUser });
  await adapter.send({ text: "log me in" });

  const deadline = Date.now() + 1000;
  while (Date.now() < deadline && outcome === undefined) await new Promise((r) => setTimeout(r, 5));

  assert.equal(asked.length, 1);
  assert.equal(asked[0].kind, "confirmAction");
  assert.match(String((asked[0] as any).preview), /auth\.example\.com/);
  assert.equal(outcome, "accept");
});

test("elicitation single-field form → input, accept with typed content", async () => {
  let res: any;
  const { transport } = pair((conn) => {
    const a = new ScriptedAgent(conn, async (sessionId) => {
      res = await conn.unstable_createElicitation({
        mode: "form",
        sessionId,
        message: "How many retries?",
        requestedSchema: {
          type: "object",
          properties: { retries: { type: "integer", description: "retry count" } },
          required: ["retries"],
        },
      } as any);
    });
    return a;
  });

  const asked: UICall[] = [];
  const askUser = async (call: UICall): Promise<UIResponse> => {
    asked.push(call);
    return { kind: "input", value: "3" };
  };

  const adapter = new AcpAdapter({ spec: { agent: "pi", command: "x" }, connect: () => transport });
  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1", askUser });
  await adapter.send({ text: "ask me" });

  const deadline = Date.now() + 1000;
  while (Date.now() < deadline && res === undefined) await new Promise((r) => setTimeout(r, 5));

  assert.equal(asked.length, 1);
  assert.equal(asked[0].kind, "input");
  assert.equal(res.action, "accept");
  assert.deepEqual(res.content, { retries: 3 }); // coerced to number
});

test("elicitation multi-field form → declines without prompting (minimal scope)", async () => {
  let res: any;
  const { transport } = pair((conn) => {
    const a = new ScriptedAgent(conn, async (sessionId) => {
      res = await conn.unstable_createElicitation({
        mode: "form",
        sessionId,
        message: "Fill the form",
        requestedSchema: {
          type: "object",
          properties: { a: { type: "string" }, b: { type: "string" } },
        },
      } as any);
    });
    return a;
  });

  const asked: UICall[] = [];
  const askUser = async (call: UICall): Promise<UIResponse> => {
    asked.push(call);
    return { kind: "input", value: "x" };
  };

  const adapter = new AcpAdapter({ spec: { agent: "pi", command: "x" }, connect: () => transport });
  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1", askUser });
  await adapter.send({ text: "go" });

  const deadline = Date.now() + 1000;
  while (Date.now() < deadline && res === undefined) await new Promise((r) => setTimeout(r, 5));

  assert.equal(asked.length, 0, "multi-field forms are not prompted in minimal scope");
  assert.equal(res.action, "decline");
});

test("elicitation declines when no phone is attached (fail safe)", async () => {
  let res: any;
  const { transport } = pair((conn) => {
    const a = new ScriptedAgent(conn, async (sessionId) => {
      res = await conn.unstable_createElicitation({
        mode: "url",
        sessionId,
        message: "open",
        elicitationId: "e1",
        url: "https://x.example",
      } as any);
    });
    return a;
  });

  const adapter = new AcpAdapter({ spec: { agent: "pi", command: "x" }, connect: () => transport });
  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1" });
  await adapter.send({ text: "go" });

  const deadline = Date.now() + 1000;
  while (Date.now() < deadline && res === undefined) await new Promise((r) => setTimeout(r, 5));
  assert.equal(res.action, "decline");
});

test("emits exit + exited status on kill", async () => {
  const { transport } = pair((conn) => new ScriptedAgent(conn, async () => {}));
  const adapter = new AcpAdapter({ spec: { agent: "pi", command: "x" }, connect: () => transport });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));

  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1" });
  const exitP = once(adapter, "exit");
  await adapter.kill();
  await exitP;

  assert.ok(events.some((e) => e.kind === "session.status" && (e.payload as any).status === "exited"));
});

test("acp defaultConnect routes a spawn failure to onExit instead of crashing the daemon", async () => {
  const transport = defaultConnect({
    agent: "test",
    command: "makit-nonexistent-binary-xyz",
  })(process.cwd(), {});
  const exit = new Promise<number | null>((resolve) => transport.onExit(resolve));
  const code = await Promise.race([
    exit,
    new Promise<number | null>((_, reject) =>
      setTimeout(() => reject(new Error("onExit never fired on spawn failure")), 2000).unref(),
    ),
  ]);
  assert.equal(code, null);
});

// ---- SPEC-26: ACP session config options ----------------------------------

/** Build an adapter paired with an agent whose newSession returns `res`. */
function pairWithNewSession(
  res: Record<string, unknown>,
  opts: {
    onSetConfigOption?: (p: { sessionId: string; configId: string; value: unknown }) => unknown;
    onInitialize?: (p: any) => void;
  } = {},
): { adapter: AcpAdapter; events: AdapterEvent[]; agentRef: () => ScriptedAgent } {
  let agentRef!: ScriptedAgent;
  const { transport } = pair((conn) => {
    agentRef = new ScriptedAgent(conn, async () => {});
    (agentRef as unknown as { newSession: () => Promise<unknown> }).newSession = async () => res;
    if (opts.onInitialize) {
      const orig = agentRef.initialize.bind(agentRef);
      (agentRef as unknown as { initialize: (p: any) => Promise<unknown> }).initialize = async (p) => {
        opts.onInitialize!(p);
        return orig(p);
      };
    }
    if (opts.onSetConfigOption) {
      (agentRef as unknown as {
        setSessionConfigOption: (p: any) => Promise<unknown>;
      }).setSessionConfigOption = async (p) => opts.onSetConfigOption!(p);
    }
    return agentRef;
  });
  const adapter = new AcpAdapter({ spec: { agent: "pi", command: "x" }, connect: () => transport });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));
  return { adapter, events, agentRef: () => agentRef };
}

test("advertises clientCapabilities.session.configOptions.boolean on initialize", async () => {
  let capabilities: any;
  const { adapter } = pairWithNewSession(
    { sessionId: "acp-sess-1" },
    { onInitialize: (p) => (capabilities = p.clientCapabilities) },
  );
  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1" });
  assert.deepEqual(capabilities.session.configOptions.boolean, {});
});

test("captures ACP configOptions and emits them ordered on session.meta", async () => {
  const { adapter, events } = pairWithNewSession({
    sessionId: "acp-sess-1",
    configOptions: [
      {
        id: "model",
        name: "Model",
        category: "model",
        type: "select",
        currentValue: "gpt-5",
        options: [
          { value: "gpt-5", name: "GPT-5" },
          { value: "o3", name: "o3", description: "reasoning" },
        ],
      },
      {
        id: "web",
        name: "Web search",
        category: "_tools",
        type: "boolean",
        currentValue: true,
      },
    ],
  });
  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1" });
  await collectUntil(events, "session.meta");
  const payload = events.find((e) => e.kind === "session.meta")!.payload as any;
  assert.deepEqual(payload.configOptions, [
    {
      id: "model",
      name: "Model",
      category: "model",
      type: "select",
      currentValue: "gpt-5",
      options: [
        { value: "gpt-5", name: "GPT-5" },
        { value: "o3", name: "o3", description: "reasoning" },
      ],
    },
    { id: "web", name: "Web search", category: "_tools", type: "boolean", currentValue: true },
  ]);
});

test("ignores modes when configOptions are present (no synthesised mode option)", async () => {
  const { adapter, events } = pairWithNewSession({
    sessionId: "acp-sess-1",
    modes: {
      currentModeId: "code",
      availableModes: [
        { id: "ask", name: "Ask" },
        { id: "code", name: "Code" },
      ],
    },
    configOptions: [
      { id: "model", name: "Model", category: "model", type: "select", currentValue: "a", options: [{ value: "a", name: "A" }] },
    ],
  });
  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1" });
  await collectUntil(events, "session.meta");
  const payload = events.find((e) => e.kind === "session.meta")!.payload as any;
  // configOptions used exclusively; no synthesised category:"mode" option.
  assert.equal(payload.configOptions.length, 1);
  assert.equal(payload.configOptions[0].id, "model");
  // Legacy modes field still emitted (additive migration window).
  assert.equal(payload.modes.current, "code");
});

test("synthesises a single category:mode option from modes-only agents", async () => {
  const { adapter, events } = pairWithNewSession({
    sessionId: "acp-sess-1",
    modes: {
      currentModeId: "code",
      availableModes: [
        { id: "ask", name: "Ask" },
        { id: "code", name: "Code" },
      ],
    },
  });
  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1" });
  await collectUntil(events, "session.meta");
  const payload = events.find((e) => e.kind === "session.meta")!.payload as any;
  assert.equal(payload.configOptions.length, 1);
  assert.deepEqual(payload.configOptions[0], {
    id: "mode",
    name: "Mode",
    category: "mode",
    type: "select",
    currentValue: "code",
    options: [
      { value: "ask", name: "Ask" },
      { value: "code", name: "Code" },
    ],
  });
});

test("parses grouped ACP select options into groups", async () => {
  const { adapter, events } = pairWithNewSession({
    sessionId: "acp-sess-1",
    configOptions: [
      {
        id: "model",
        name: "Model",
        category: "model",
        type: "select",
        currentValue: "gpt-5",
        options: [
          { group: "openai", name: "OpenAI", options: [{ value: "gpt-5", name: "GPT-5" }] },
          { group: "anthropic", name: "Anthropic", options: [{ value: "sonnet", name: "Sonnet" }] },
        ],
      },
    ],
  });
  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1" });
  await collectUntil(events, "session.meta");
  const payload = events.find((e) => e.kind === "session.meta")!.payload as any;
  assert.equal(payload.configOptions[0].options, undefined);
  assert.deepEqual(payload.configOptions[0].groups, [
    { name: "OpenAI", options: [{ value: "gpt-5", name: "GPT-5" }] },
    { name: "Anthropic", options: [{ value: "sonnet", name: "Sonnet" }] },
  ]);
});

test("configOption action → session/set_config_option; complete response list replaces + re-emits", async () => {
  const setCalls: any[] = [];
  const { adapter, events } = pairWithNewSession(
    {
      sessionId: "acp-sess-1",
      configOptions: [
        { id: "model", name: "Model", category: "model", type: "select", currentValue: "gpt-5", options: [{ value: "gpt-5", name: "GPT-5" }, { value: "o3", name: "o3" }] },
        { id: "reasoning", name: "Reasoning", category: "thought_level", type: "select", currentValue: "low", options: [{ value: "low", name: "Low" }] },
      ],
    },
    {
      onSetConfigOption: (p) => {
        setCalls.push(p);
        // Dependent option recompute: switching model changes reasoning choices.
        return {
          configOptions: [
            { id: "model", name: "Model", category: "model", type: "select", currentValue: "o3", options: [{ value: "gpt-5", name: "GPT-5" }, { value: "o3", name: "o3" }] },
            { id: "reasoning", name: "Reasoning", category: "thought_level", type: "select", currentValue: "high", options: [{ value: "high", name: "High" }] },
          ],
        };
      },
    },
  );
  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1" });
  await collectUntil(events, "session.meta");

  events.length = 0;
  await adapter.sendAction!("configOption", { id: "model", value: "o3" });
  assert.deepEqual(setCalls.at(-1), { sessionId: "acp-sess-1", configId: "model", value: "o3" });
  await collectUntil(events, "session.meta");
  const payload = events.find((e) => e.kind === "session.meta")!.payload as any;
  // The COMPLETE response list replaced the cached options (never merged).
  assert.equal(payload.configOptions[0].currentValue, "o3");
  assert.equal(payload.configOptions[1].currentValue, "high");
  assert.deepEqual(payload.configOptions[1].options, [{ value: "high", name: "High" }]);
});

test("boolean configOption action sends type:boolean and a boolean value", async () => {
  const setCalls: any[] = [];
  const { adapter, events } = pairWithNewSession(
    {
      sessionId: "acp-sess-1",
      configOptions: [{ id: "web", name: "Web", category: "_tools", type: "boolean", currentValue: false }],
    },
    {
      onSetConfigOption: (p) => {
        setCalls.push(p);
        return { configOptions: [{ id: "web", name: "Web", category: "_tools", type: "boolean", currentValue: true }] };
      },
    },
  );
  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1" });
  await collectUntil(events, "session.meta");
  events.length = 0;
  await adapter.sendAction!("configOption", { id: "web", value: true });
  assert.deepEqual(setCalls.at(-1), { sessionId: "acp-sess-1", configId: "web", value: true, type: "boolean" });
  await collectUntil(events, "session.meta");
  assert.equal((events.find((e) => e.kind === "session.meta")!.payload as any).configOptions[0].currentValue, true);
});

test("config_option_update notification re-emits the complete configOptions list", async () => {
  const { adapter, events, agentRef } = pairWithNewSession({
    sessionId: "acp-sess-1",
    configOptions: [{ id: "model", name: "Model", category: "model", type: "select", currentValue: "gpt-5", options: [{ value: "gpt-5", name: "GPT-5" }, { value: "o3", name: "o3" }] }],
  });
  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1" });
  await collectUntil(events, "session.meta");
  events.length = 0;
  await agentRef().update("acp-sess-1", {
    sessionUpdate: "config_option_update",
    configOptions: [{ id: "model", name: "Model", category: "model", type: "select", currentValue: "o3", options: [{ value: "gpt-5", name: "GPT-5" }, { value: "o3", name: "o3" }] }],
  });
  await collectUntil(events, "session.meta");
  assert.equal((events.find((e) => e.kind === "session.meta")!.payload as any).configOptions[0].currentValue, "o3");
});

test("modes-only agent routes a configOption id:mode to set_session_mode (no set_config_option)", async () => {
  const setModeCalls: any[] = [];
  const setConfigCalls: any[] = [];
  let agentRef!: ScriptedAgent;
  const { transport } = pair((conn) => {
    agentRef = new ScriptedAgent(conn, async () => {});
    (agentRef as unknown as { newSession: () => Promise<unknown> }).newSession = async () => ({
      sessionId: "acp-sess-1",
      modes: { currentModeId: "code", availableModes: [{ id: "ask", name: "Ask" }, { id: "code", name: "Code" }] },
    });
    (agentRef as unknown as { setSessionMode: (p: any) => Promise<unknown> }).setSessionMode = async (p) => {
      setModeCalls.push(p);
      return {};
    };
    (agentRef as unknown as { setSessionConfigOption: (p: any) => Promise<unknown> }).setSessionConfigOption = async (p) => {
      setConfigCalls.push(p);
      return { configOptions: [] };
    };
    return agentRef;
  });
  const adapter = new AcpAdapter({ spec: { agent: "pi", command: "x" }, connect: () => transport });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));
  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1" });
  await collectUntil(events, "session.meta");
  events.length = 0;
  await adapter.sendAction!("configOption", { id: "mode", value: "ask" });
  assert.deepEqual(setModeCalls.at(-1), { sessionId: "acp-sess-1", modeId: "ask" });
  assert.equal(setConfigCalls.length, 0);
  await collectUntil(events, "session.meta");
  assert.equal((events.find((e) => e.kind === "session.meta")!.payload as any).configOptions[0].currentValue, "ask");
});

// ---------- capability probe (SPEC-27) -------------------------------------

/**
 * Build a probe-facing fake agent: newSession returns `res`; initialize
 * advertises `session/delete` iff `supportsDelete`; deleteSession is recorded.
 */
function probePair(
  res: Record<string, unknown>,
  opts: { supportsDelete?: boolean } = {},
): { transport: AcpTransport; deleteCalls: { sessionId: string }[] } {
  const deleteCalls: { sessionId: string }[] = [];
  const { transport } = pair((conn) => {
    const agent = new ScriptedAgent(conn, async () => {});
    (agent as unknown as { initialize: () => Promise<unknown> }).initialize = async () => ({
      protocolVersion: 1 as const,
      agentCapabilities: {
        loadSession: false,
        ...(opts.supportsDelete ? { sessionCapabilities: { delete: {} } } : {}),
      },
    });
    (agent as unknown as { newSession: () => Promise<unknown> }).newSession = async () => res;
    (agent as unknown as { deleteSession: (p: { sessionId: string }) => Promise<unknown> }).deleteSession =
      async (p) => {
        deleteCalls.push(p);
        return {};
      };
    return agent;
  });
  return { transport, deleteCalls };
}

test("probeAcpConfigOptions captures configOptions from session/new and deletes the probe session", async () => {
  const { transport, deleteCalls } = probePair(
    {
      sessionId: "probe-sess-1",
      configOptions: [
        {
          id: "model",
          name: "Model",
          category: "model",
          type: "select",
          currentValue: "gpt-5",
          options: [
            { value: "gpt-5", name: "GPT-5" },
            { value: "o3", name: "o3" },
          ],
        },
      ],
    },
    { supportsDelete: true },
  );

  const options = await probeAcpConfigOptions(
    { agent: "pi", command: "x" },
    { connect: () => transport },
  );
  assert.equal(options.length, 1);
  assert.equal(options[0].id, "model");
  assert.equal(options[0].currentValue, "gpt-5");
  // The throwaway session was dropped via session/delete.
  assert.deepEqual(deleteCalls, [{ sessionId: "probe-sess-1" }]);
});

test("probeAcpConfigOptions returns [] for an option-less harness and skips delete when unadvertised", async () => {
  const { transport, deleteCalls } = probePair(
    { sessionId: "probe-sess-2" },
    { supportsDelete: false },
  );
  const options = await probeAcpConfigOptions(
    { agent: "pi", command: "x" },
    { connect: () => transport },
  );
  assert.deepEqual(options, []);
  // No delete capability advertised → probe does not call session/delete.
  assert.equal(deleteCalls.length, 0);
});

test("listAcpSessions returns normalized sessions when the agent advertises list (SPEC-29)", async () => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "makit-acp-list-")));
  try {
    const { transport } = pair((_conn) => ({
      async initialize(_p: InitializeRequest) {
        return {
          protocolVersion: 1 as const,
          agentCapabilities: { loadSession: true, sessionCapabilities: { list: {} } },
        };
      },
      async newSession(_p: NewSessionRequest) {
        return { sessionId: "s1" };
      },
      async authenticate() {},
      async prompt(): Promise<PromptResponse> {
        return { stopReason: "end_turn" };
      },
      async listSessions(_p: unknown) {
        return {
          sessions: [
            { sessionId: "a", cwd: dir, title: "First", updatedAt: "2026-07-26T10:00:00Z", _meta: { messageCount: 4 } },
            { sessionId: "b", cwd: dir, updatedAt: "not-a-date" },
          ],
        };
      },
    }) as unknown as Agent);

    const out = await listAcpSessions({ agent: "pi", command: "x" }, dir, { connect: () => transport });
    assert.equal(out.length, 2);
    assert.deepEqual(out[0], { id: "a", cwd: dir, title: "First", updatedAt: Date.parse("2026-07-26T10:00:00Z"), messageCount: 4 });
    // Unparseable updatedAt is dropped rather than NaN.
    assert.equal(out[1].id, "b");
    assert.equal(out[1].updatedAt, undefined);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("listAcpSessions returns [] when the agent does not advertise list", async () => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "makit-acp-nolist-")));
  try {
    const { transport } = pair(() => ({
      async initialize(_p: InitializeRequest) {
        return { protocolVersion: 1 as const, agentCapabilities: { loadSession: false } };
      },
      async newSession(_p: NewSessionRequest) {
        return { sessionId: "s1" };
      },
      async authenticate() {},
      async prompt(): Promise<PromptResponse> {
        return { stopReason: "end_turn" };
      },
    }) as unknown as Agent);
    const out = await listAcpSessions({ agent: "pi", command: "x" }, dir, { connect: () => transport });
    assert.deepEqual(out, []);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("deriveAcpCapabilities reads loadSession + sessionCapabilities (SPEC-29)", () => {
  assert.deepEqual(
    deriveAcpCapabilities({ agentCapabilities: { loadSession: true, sessionCapabilities: { list: {}, delete: {} } } }),
    { resume: false, load: true, list: true, delete: true, fork: false, archive: false },
  );
  assert.deepEqual(
    deriveAcpCapabilities({ agentCapabilities: { sessionCapabilities: { resume: {}, fork: {} } } }),
    { resume: true, load: false, list: false, delete: false, fork: true, archive: false },
  );
  // Missing / malformed → all false.
  assert.deepEqual(deriveAcpCapabilities({}), { resume: false, load: false, list: false, delete: false, fork: false, archive: false });
  assert.deepEqual(deriveAcpCapabilities(null), { resume: false, load: false, list: false, delete: false, fork: false, archive: false });
});

test("start({resumeAgentSessionId}) loads and drops the replayed history (silent mode, SPEC-29)", async () => {
  let loadArgs: any;
  const { transport } = pair((conn) => ({
    async initialize(_p: InitializeRequest) {
      return { protocolVersion: 1 as const, agentCapabilities: { loadSession: true } };
    },
    async newSession(_p: NewSessionRequest) {
      return { sessionId: "should-not-be-called" };
    },
    async loadSession(p: any) {
      loadArgs = p;
      // Replay a historical turn DURING load — the client must drop it.
      await conn.sessionUpdate({
        sessionId: p.sessionId,
        update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "OLD HISTORY" } },
      });
      return {};
    },
    async authenticate() {},
    async prompt(): Promise<PromptResponse> {
      return { stopReason: "end_turn" };
    },
  }) as unknown as Agent);

  const adapter = new AcpAdapter({ spec: { agent: "pi", command: "x" }, connect: () => transport });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));
  await adapter.start({ cwd: process.cwd(), sessionId: "m1", resumeAgentSessionId: "acp-prev" });

  // Resumed by native id via session/load — never session/new.
  assert.equal(loadArgs.sessionId, "acp-prev");
  assert.equal(adapter.agentSessionId, "acp-prev");
  // The replayed history was dropped (not appended to makit's log).
  assert.ok(!events.some((e) => e.kind === "agent.message" && (e.payload as any)?.text === "OLD HISTORY"));
});

test("ingests a tool-result image and rewrites a local markdown image path", async () => {
  // Real MediaStore in a temp dir — this exercises the whole SPEC-22 server
  // path: base64 tool output → blob, and `![](abs path)` → makit-media URI.
  const cwd = realpathSync(mkdtempSync(join(tmpdir(), "makit-acp-media-")));
  const png = Buffer.from(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000a49444154789c6300010000050001",
    "hex",
  );
  writeFileSync(join(cwd, "shot.png"), png);
  const store = new MediaStore({ dir: join(cwd, ".media") });

  let agentRef: ScriptedAgent;
  const { transport } = pair((conn) => {
    agentRef = new ScriptedAgent(conn, async (sessionId) => {
      await agentRef.update(sessionId, {
        sessionUpdate: "tool_call",
        toolCallId: "t1",
        title: "read",
        kind: "read",
        status: "pending",
      } as never);
      await agentRef.update(sessionId, {
        sessionUpdate: "tool_call_update",
        toolCallId: "t1",
        status: "completed",
        content: [{ type: "content", content: { type: "text", text: "Read image file [image/png]" } }],
        rawOutput: { content: [{ type: "image", data: png.toString("base64"), mimeType: "image/png" }] },
      } as never);
      await agentRef.update(sessionId, {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: `here it is ![shot](${join(cwd, "shot.png")})` },
      });
    });
    return agentRef;
  });

  const adapter = new AcpAdapter({
    spec: { agent: "pi", command: "x" },
    connect: () => transport,
    media: store,
  });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));

  await adapter.start({ cwd, sessionId: "makit-media-1" });
  await adapter.send({ text: "read the png and show me" });
  await collectUntil(events, "agent.message");

  // 1. Tool-result bytes became a servable blob + an agent.media event.
  const media = events.find((e) => e.kind === "agent.media")!.payload as {
    mediaId: string;
    mime: string;
    callId: string;
  };
  assert.equal(media.mime, "image/png");
  assert.equal(media.callId, "t1");
  assert.equal(store.stat(media.mediaId)?.sizeBytes, png.length);

  // 2. The local path in prose became a makit-media URI for the same bytes
  //    (content addressing ⇒ identical file ⇒ identical id).
  const text = (events.find((e) => e.kind === "agent.message")!.payload as { text: string }).text;
  assert.equal(text, `here it is ![shot](makit-media:${media.mediaId})`);
});

test("a genuine tool approval is not hijacked by a rawInput.method field", async () => {
  let agentRef: ScriptedAgent;
  let outcome: string | undefined;
  const { transport } = pair((conn) => {
    agentRef = new ScriptedAgent(conn, async (sessionId) => {
      // A REAL execute-tool approval that happens to carry `method: "confirm"`
      // in its arguments must still get the confirmAction modal (with its
      // command preview), not an inline pick list.
      const res = await conn.requestPermission({
        sessionId,
        toolCall: {
          toolCallId: "tool-42",
          title: "rm -rf build",
          kind: "execute",
          status: "pending",
          rawInput: { command: "rm -rf build", method: "confirm" },
        } as any,
        options: [
          { optionId: "ok", name: "Allow", kind: "allow_once" },
          { optionId: "no", name: "Reject", kind: "reject_once" },
        ],
      });
      outcome = res.outcome.outcome === "selected" ? res.outcome.optionId : "cancelled";
    });
    return agentRef;
  });

  const asked: UICall[] = [];
  const askUser = async (call: UICall): Promise<UIResponse> => {
    asked.push(call);
    return { kind: "confirmAction", approved: true };
  };

  const adapter = new AcpAdapter({ spec: { agent: "pi", command: "x" }, connect: () => transport });
  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1", askUser });
  await adapter.send({ text: "danger" });

  const deadline = Date.now() + 1000;
  while (Date.now() < deadline && outcome === undefined) {
    await new Promise((r) => setTimeout(r, 5));
  }

  assert.equal(asked.length, 1);
  assert.equal(asked[0].kind, "confirmAction");
  assert.equal(outcome, "ok");
});
