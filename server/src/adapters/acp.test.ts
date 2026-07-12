import { test } from "node:test";
import assert from "node:assert/strict";
import { once } from "node:events";
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
import { AcpAdapter, type AcpTransport } from "./acp.js";
import type { AdapterEvent } from "./adapter.js";
import type { UICall, UIResponse } from "../uicall.js";

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
