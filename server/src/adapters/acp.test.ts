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
import { Session } from "../session.js";

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

test("acp start fails with the missing binary's name, not a bare connection close", async () => {
  // A GUI-launched daemon inherits launchd's PATH, so `pi-acp` does not resolve
  // and the SDK rejects the handshake with the useless "ACP connection closed".
  // The user needs to be told WHICH binary is missing.
  const adapter = new AcpAdapter({
    spec: { agent: "pi", command: "makit-nonexistent-binary-xyz" },
  });
  await assert.rejects(
    () => adapter.start({ cwd: process.cwd(), sessionId: "makit-1" }),
    (e: Error) => {
      assert.match(e.message, /makit-nonexistent-binary-xyz/, "names the binary");
      assert.match(e.message, /not found on PATH/, "says what is wrong");
      return true;
    },
  );
});

test("acp start preflight honors spec.env.PATH — not just the parent process PATH", async () => {
  // `spawnLineProcess` runs the child with `{ ...process.env, ...opts.env }`
  // as its env, so a spec-supplied PATH reaches the child. The preflight must
  // mirror that: a bin only reachable via spec.env.PATH must not be falsely
  // rejected as "not found on PATH". Otherwise a caller that intentionally
  // widens PATH for the child never gets past start().
  const dir = mkdtempSync(join(tmpdir(), "makit-acp-preflight-"));
  const bin = join(dir, "makit-preflight-bin");
  writeFileSync(bin, "#!/bin/sh\nexit 0\n", { mode: 0o755 });
  const savedPath = process.env.PATH;
  process.env.PATH = "/usr/bin:/bin:/usr/sbin:/sbin"; // launchd-minimal
  try {
    const adapter = new AcpAdapter({
      spec: { agent: "pi", command: "makit-preflight-bin", env: { PATH: dir } },
    });
    // The bin exits immediately so the SDK will fail the handshake with
    // "ACP connection closed" — which is exactly the failure we want to reach,
    // proving the preflight passed. Rejecting with "not found on PATH" would
    // mean the preflight ignored spec.env.PATH.
    await assert.rejects(
      () => adapter.start({ cwd: process.cwd(), sessionId: "makit-1" }),
      (e: Error) => {
        assert.doesNotMatch(
          e.message,
          /not found on PATH/,
          "preflight must consult spec.env.PATH",
        );
        return true;
      },
    );
  } finally {
    process.env.PATH = savedPath;
    rmSync(dir, { recursive: true, force: true });
  }
});

// ---- SPEC-acp-config-options-unified-composer: ACP session config options ----------------------------------

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

// ---------- capability probe (SPEC-new-session-config-at-spawn) -------------------------------------

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

test("listAcpSessions returns normalized sessions when the agent advertises list (SPEC-session-lifecycle-resume-list-delete)", async () => {
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

test("deriveAcpCapabilities reads loadSession + sessionCapabilities (SPEC-session-lifecycle-resume-list-delete)", () => {
  assert.deepEqual(
    deriveAcpCapabilities({ agentCapabilities: { loadSession: true, sessionCapabilities: { list: {}, delete: {} } } }),
    { resume: false, load: true, list: true, delete: true, fork: false, archive: false, close: false },
  );
  assert.deepEqual(
    deriveAcpCapabilities({ agentCapabilities: { sessionCapabilities: { resume: {}, fork: {} } } }),
    { resume: true, load: false, list: false, delete: false, fork: true, archive: false, close: false },
  );
  // `close` is its own capability (SPEC-session-lifecycle-resume-list-delete close/reopen) — `{}` means supported.
  assert.deepEqual(
    deriveAcpCapabilities({ agentCapabilities: { sessionCapabilities: { close: {} } } }),
    { resume: false, load: false, list: false, delete: false, fork: false, archive: false, close: true },
  );
  // Missing / malformed → all false.
  assert.deepEqual(deriveAcpCapabilities({}), { resume: false, load: false, list: false, delete: false, fork: false, archive: false, close: false });
  assert.deepEqual(deriveAcpCapabilities(null), { resume: false, load: false, list: false, delete: false, fork: false, archive: false, close: false });
});

/**
 * `close()` is the graceful half of freeing a session: ACP `session/close`
 * cancels any in-flight turn and releases the agent's resources, and only then
 * does the caller tear the transport down. Verifies the call reaches the wire
 * carrying the live sessionId.
 */
test("close() sends session/close when the agent advertises the capability", async () => {
  const closed: string[] = [];
  const { transport } = pair((conn) => {
    const a = new ScriptedAgent(conn, async () => {});
    (a as unknown as { initialize: () => Promise<unknown> }).initialize = async () => ({
      protocolVersion: 1 as const,
      agentCapabilities: { sessionCapabilities: { close: {} } },
    });
    (a as unknown as { closeSession: (p: { sessionId: string }) => Promise<unknown> }).closeSession =
      async (p) => {
        closed.push(p.sessionId);
        return {};
      };
    return a;
  });

  const adapter = new AcpAdapter({ spec: { agent: "codex", command: "x" }, connect: () => transport });
  await adapter.start({ cwd: "/tmp" });
  assert.equal(adapter.capabilities.close, true);

  await adapter.close();
  assert.deepEqual(closed, ["acp-sess-1"]);
});

test("close() is a no-op when the agent does not advertise session/close", async () => {
  const closed: string[] = [];
  const { transport } = pair((conn) => {
    const a = new ScriptedAgent(conn, async () => {});
    (a as unknown as { closeSession: (p: { sessionId: string }) => Promise<unknown> }).closeSession =
      async (p) => {
        closed.push(p.sessionId);
        return {};
      };
    return a;
  });

  const adapter = new AcpAdapter({ spec: { agent: "codex", command: "x" }, connect: () => transport });
  await adapter.start({ cwd: "/tmp" });
  assert.equal(adapter.capabilities.close, false);

  await adapter.close();
  assert.deepEqual(closed, [], "must not call an unadvertised method");
});

/**
 * The adapter makes the plain request and lets a failure surface;
 * `SessionManager.closeSession` owns bounding and swallowing it (and reaps
 * regardless). Asserted so the contract cannot quietly drift back to each
 * adapter half-handling teardown policy on its own.
 */
test("close() propagates a failing session/close for the manager to absorb", async () => {
  const { transport } = pair((conn) => {
    const a = new ScriptedAgent(conn, async () => {});
    (a as unknown as { initialize: () => Promise<unknown> }).initialize = async () => ({
      protocolVersion: 1 as const,
      agentCapabilities: { sessionCapabilities: { close: {} } },
    });
    (a as unknown as { closeSession: () => Promise<unknown> }).closeSession = async () => {
      throw new Error("agent is wedged");
    };
    return a;
  });

  const adapter = new AcpAdapter({ spec: { agent: "codex", command: "x" }, connect: () => transport });
  await adapter.start({ cwd: "/tmp" });

  await assert.rejects(() => adapter.close());
});

test("start({resumeAgentSessionId}) loads and drops the replayed history (silent mode, SPEC-session-lifecycle-resume-list-delete)", async () => {
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
  const statuses: string[] = [];
  adapter.on("event", (e) => events.push(e));
  adapter.on("status", (s) => statuses.push(s));
  await adapter.start({ cwd: process.cwd(), sessionId: "m1", resumeAgentSessionId: "acp-prev" });

  // Resumed by native id via session/load — never session/new.
  assert.equal(loadArgs.sessionId, "acp-prev");
  assert.equal(adapter.agentSessionId, "acp-prev");
  // The replayed history was dropped (not appended to makit's log).
  assert.ok(!events.some((e) => e.kind === "agent.message" && (e.payload as any)?.text === "OLD HISTORY"));
  // And it did not read as live work: a resumed session must not come up
  // "running" on history alone, or every later message queues behind a turn
  // that no agent is running.
  assert.equal(statuses.includes("running"), false);
});

test("ingests a tool-result image and rewrites a local markdown image path", async () => {
  // Real MediaStore in a temp dir — this exercises the whole SPEC-assistant-display-media server
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

test("acp cannot steer: ACP has no mid-turn injection primitive (SPEC-mid-turn-steering-and-queue T1)", async () => {
  const { adapter, events } = pairWithNewSession({ sessionId: "acp-sess-1" });
  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1" });
  const before = events.length;

  assert.equal(await adapter.steer({ text: "mid-turn" }), false);
  assert.equal(events.length, before, "steer() must not echo or emit anything");
});

// ---------------------------------------------------------------------------
// SpawnOpts.model on the ACP path
//
// pi runs behind the `pi-acp` bridge, whose argv is fixed (`--mode rpc
// --no-themes` [+ --session]) — it forwards neither `--model` nor `-e`. So a
// requested model can only be delivered over ACP, via the SPEC-acp-config-options-unified-composer config-option
// surface. Before this, `SpawnOpts.model` was silently dropped for pi: the real
// e2e loop believed it had swapped in the local fake model while actually
// billing the user's configured one.
// ---------------------------------------------------------------------------

/** A scripted agent advertising a `model` select, recording config-option sets. */
function modelAwarePair(values: string[], current: string) {
  const sets: { configId: string; value: unknown }[] = [];
  const { transport } = pair((conn) => {
    const a = new ScriptedAgent(conn, async () => {});
    const cfg = {
      configOptions: [
        {
          id: "model",
          name: "Model",
          type: "select",
          currentValue: current,
          options: values.map((v) => ({ value: v, name: v })),
        },
      ],
    };
    (a as unknown as { newSession: () => Promise<unknown> }).newSession = async () => ({
      sessionId: "acp-sess-1",
      ...cfg,
    });
    (a as unknown as {
      setSessionConfigOption: (p: { configId: string; value: unknown }) => Promise<unknown>;
    }).setSessionConfigOption = async (p) => {
      sets.push({ configId: p.configId, value: p.value });
      return {
        configOptions: [{ ...cfg.configOptions[0], currentValue: String(p.value) }],
      };
    };
    return a;
  });
  return { transport, sets };
}

test("start() applies a requested model through the ACP config-option surface", async () => {
  const { transport, sets } = modelAwarePair(
    ["real/expensive-1", "makit-fake/fake-1"],
    "real/expensive-1",
  );
  const adapter = new AcpAdapter({
    spec: { agent: "pi", command: "unused" },
    connect: () => transport,
    media: undefined,
  });
  await adapter.start({ cwd: process.cwd(), sessionId: "s1", model: "makit-fake/fake-1" });
  assert.deepEqual(
    sets,
    [{ configId: "model", value: "makit-fake/fake-1" }],
    "the requested model was actually selected on the agent",
  );
  await adapter.kill();
});

test("start() leaves the agent's model alone when it already matches, or is unknown", async () => {
  // Already current: no redundant round-trip.
  const same = modelAwarePair(["makit-fake/fake-1"], "makit-fake/fake-1");
  const a1 = new AcpAdapter({ spec: { agent: "pi", command: "unused" }, connect: () => same.transport });
  await a1.start({ cwd: process.cwd(), sessionId: "s1", model: "makit-fake/fake-1" });
  assert.deepEqual(same.sets, [], "no set call when the model is already current");
  await a1.kill();

  // Not offered by this agent: must NOT be sent (the agent would reject it), and
  // the session must still come up live rather than failing to start.
  const missing = modelAwarePair(["real/expensive-1"], "real/expensive-1");
  const a2 = new AcpAdapter({ spec: { agent: "pi", command: "unused" }, connect: () => missing.transport });
  const statuses: string[] = [];
  a2.on("status", (s: string) => statuses.push(s));
  await a2.start({ cwd: process.cwd(), sessionId: "s2", model: "makit-fake/fake-1" });
  assert.deepEqual(missing.sets, [], "an unoffered model is never sent to the agent");
  assert.ok(statuses.includes("idle"), "the session still started");
  await a2.kill();
});

test("an agent that keeps working after its prompt resolved stays running", async () => {
  // The field incident: pi-acp resolves `session/prompt` on pi's `agent_end`,
  // and pi emits more than one of those per prompt. makit therefore left the
  // turn while the agent carried on, and one session streamed 6,147 events with
  // `status: idle` — no working shimmer, no live dot, for an hour.
  let agentRef!: ScriptedAgent;
  const { transport } = pair((conn) => {
    agentRef = new ScriptedAgent(conn, async () => {
      // Answer the prompt at once, the way a duplicate `agent_end` does.
    });
    return agentRef;
  });

  const adapter = new AcpAdapter({ spec: { agent: "pi", command: "x" }, connect: () => transport });
  const all: string[] = [];
  const events: AdapterEvent[] = [];
  adapter.on("status", (s) => all.push(s));
  adapter.on("event", (e) => events.push(e));

  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1" });
  // `start` settles to idle; the turn transitions are what this test is about.
  const from = all.length;
  const statuses = () => all.slice(from);
  await adapter.send({ text: "go" });
  await collectUntil(events, "user.message");
  // The prompt settled early, so makit reported idle here.
  await new Promise((r) => setTimeout(r, 20));
  assert.deepEqual(statuses(), ["running", "idle"]);

  // The agent is not finished: it streams on.
  await agentRef.update("acp-sess-1", {
    sessionUpdate: "agent_thought_chunk",
    content: { type: "text", text: "still thinking" },
  });
  await collectUntil(events, "agent.thinking.delta");
  assert.deepEqual(statuses(), ["running", "idle", "running"], "the stream re-opens the turn");

  // Now the agent really stops, and says so.
  await agentRef.update("acp-sess-1", {
    sessionUpdate: "session_info_update",
    _meta: { piAcp: { queueDepth: 0, running: false } },
  });
  await new Promise((r) => setTimeout(r, 20));
  assert.deepEqual(statuses(), ["running", "idle", "running", "idle"]);
});

test("a silent agent that reported itself running stays running past its prompt", async () => {
  // Work evidence cannot cover this one: the agent says `running: true`, answers
  // the prompt early (a duplicate `agent_end`), then spends minutes inside a
  // tool that streams nothing. With the running flag derived from the prompt
  // turn, `.finally()` dropped it and the session reported `idle` mid-work.
  let agentRef!: ScriptedAgent;
  const { transport } = pair((conn) => {
    agentRef = new ScriptedAgent(conn, async (sessionId) => {
      // The agent announces the turn, then answers the prompt at once.
      await agentRef.update(sessionId, {
        sessionUpdate: "session_info_update",
        _meta: { piAcp: { queueDepth: 0, running: true } },
      });
    });
    return agentRef;
  });

  const adapter = new AcpAdapter({ spec: { agent: "pi", command: "x" }, connect: () => transport });
  const all: string[] = [];
  const events: AdapterEvent[] = [];
  adapter.on("status", (s) => all.push(s));
  adapter.on("event", (e) => events.push(e));

  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1" });
  const from = all.length;
  const statuses = () => all.slice(from);
  await adapter.send({ text: "go" });
  await collectUntil(events, "user.message");
  await new Promise((r) => setTimeout(r, 20));

  assert.deepEqual(statuses(), ["running"], "the agent said it is working: no idle");

  // It finally stops, and says so — the only thing that may settle it.
  await agentRef.update("acp-sess-1", {
    sessionUpdate: "session_info_update",
    _meta: { piAcp: { queueDepth: 0, running: false } },
  });
  await new Promise((r) => setTimeout(r, 20));
  assert.deepEqual(statuses(), ["running", "idle"]);
});

test("a live adapter can release the busy state one post-turn chunk pinned", async () => {
  // End to end over a real AcpAdapter, because the guard is only worth anything
  // if the adapter is wired to it: the tracker's release must be reachable
  // through `releaseStrayBusy`, which is what Session calls before it queues.
  let agentRef: ScriptedAgent;
  const { transport } = pair((conn) => {
    agentRef = new ScriptedAgent(conn, async (sessionId) => {
      await agentRef.update(sessionId, {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "done" },
      });
      // pi-acp reports the end of work at `agent_end`.
      await agentRef.update(sessionId, {
        sessionUpdate: "session_info_update",
        _meta: { piAcp: { queueDepth: 0, running: false } },
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
  assert.equal(statuses.at(-1), "idle", "the turn ended");
  assert.equal(adapter.releaseStrayBusy(), false, "nothing to release while idle");

  // Now one chunk with no turn around it: a pi extension notifying after the
  // turn (this one without pi-acp's notify flag, so it counts as work).
  await agentRef!.update("acp-sess-1", {
    sessionUpdate: "agent_message_chunk",
    content: { type: "text", text: "💾 Memory auto-reviewed and updated" },
  });
  await collectUntil(events, "agent.message.delta");
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(statuses.at(-1), "running", "the stray chunk re-opened a turn");

  assert.equal(adapter.releaseStrayBusy(), true);
  assert.equal(statuses.at(-1), "idle", "and the session can take a message again");

  await adapter.kill();
});

test("a live adapter ignores a post-turn notification for turn state", async () => {
  // The exact update pi-acp sends for a pi extension's `ui.notify`: a message
  // chunk flagged `_meta.piAcp.notify`. It must reach the client as text and
  // leave the turn state alone, so the session stays ready for the next message.
  let agentRef: ScriptedAgent;
  const { transport } = pair((conn) => {
    agentRef = new ScriptedAgent(conn, async (sessionId) => {
      await agentRef.update(sessionId, {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "done" },
      });
      await agentRef.update(sessionId, {
        sessionUpdate: "session_info_update",
        _meta: { piAcp: { queueDepth: 0, running: false } },
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
  const settled = statuses.length;
  assert.equal(statuses.at(-1), "idle");

  await agentRef!.update("acp-sess-1", {
    sessionUpdate: "agent_message_chunk",
    content: { type: "text", text: "💾 Memory auto-reviewed and updated" },
    _meta: { piAcp: { notify: { level: "info" } } },
  });
  await collectUntil(events, "agent.message.delta");
  await new Promise((r) => setTimeout(r, 20));

  assert.equal(statuses.length, settled, "no status transition from a notification");
  assert.equal(statuses.at(-1), "idle", "the session is still ready for a message");
  assert.equal(adapter.releaseStrayBusy(), false, "there was never a stray turn to release");

  await adapter.kill();
});

test("a session wedged by a post-turn chunk delivers the next message to the real adapter", async () => {
  // The production path, end to end and with no fake in it: Session ->
  // SubprocessAdapter.releaseStrayBusy -> TurnStatusTracker -> AcpAdapter.send ->
  // the wire. This is the exact route the recorded defect took, and the one a
  // fake adapter in session.test.ts cannot prove.
  const prompts: string[] = [];
  let agentRef: ScriptedAgent;
  const { transport } = pair((conn) => {
    agentRef = new ScriptedAgent(conn, async (sessionId, text) => {
      prompts.push(text);
      await agentRef.update(sessionId, {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "ok" },
      });
      await agentRef.update(sessionId, {
        sessionUpdate: "session_info_update",
        _meta: { piAcp: { queueDepth: 0, running: false } },
      });
    });
    return agentRef;
  });

  const adapter = new AcpAdapter({ spec: { agent: "pi", command: "x" }, connect: () => transport });
  const session = new Session({ projectId: "p", agent: "pi", adapter });
  await adapter.start({ cwd: process.cwd(), sessionId: "makit-1" });

  await session.sendUserMessage("first");
  await collectUntil(session.events as unknown as AdapterEvent[], "agent.message");
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(session.status, "idle");

  // One chunk outside any turn: the memory extension notifying after the turn,
  // as pi-acp forwarded it before it flagged notifications.
  await agentRef!.update("acp-sess-1", {
    sessionUpdate: "agent_message_chunk",
    content: { type: "text", text: "💾 Memory auto-reviewed and updated" },
  });
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(session.status, "running", "the session is wedged");

  await session.sendUserMessage("second");
  await new Promise((r) => setTimeout(r, 60));

  assert.deepEqual(prompts, ["first", "second"], "both prompts reached the agent");
  assert.equal(session.queuedMessages.length, 0, "nothing stranded in the queue");

  await adapter.kill();
});
