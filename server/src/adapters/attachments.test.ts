/**
 * Adapter attachment delivery (SPEC-33 T5) — the file hand-off, on both
 * transports.
 *
 * v1 delivers an attachment by copying it into the session's worktree and naming
 * the path in the prompt (spec §3.4a), because that works on every agent with no
 * capability negotiation. Two invariants are tested here for each adapter:
 *
 * 1. The **prompt** the agent receives names the file.
 * 2. The **`user.message` echo** carries the user's original text (NOT the
 *    path-suffixed prompt) plus the attachment descriptors — that echo is what
 *    the transcript renders, so a suffixed echo would show the user plumbing
 *    they never typed.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
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

import { AcpAdapter, type AcpTransport } from "./acp.js";
import { CodexAppServerAdapter, type CodexTransport } from "./codex.js";
import type { AdapterEvent } from "./adapter.js";
import { MediaStore, type MediaAttachment } from "../media/store.js";
import { ATTACHMENTS_DIR, prepareTurnOrFail } from "../media/attach.js";

const png = Buffer.from("fake-png-bytes");

function tmp(prefix: string): string {
  return mkdtempSync(join(tmpdir(), `makit-t5-${prefix}-`));
}

/** A worktree that is a real git repo, so the exclude path is exercised too. */
function gitWorktree(): string {
  const dir = tmp("wt");
  const g = (...args: string[]) => execFileSync("git", args, { cwd: dir, stdio: "ignore" });
  execFileSync("git", ["init", "-q", "-b", "main", dir], { stdio: "ignore" });
  g("config", "user.email", "t@example.com");
  g("config", "user.name", "T");
  writeFileSync(join(dir, "README.md"), "hi\n");
  g("add", "-A");
  g("commit", "-qm", "init");
  return dir;
}

function storedPng(): { store: MediaStore; attachment: MediaAttachment } {
  const store = new MediaStore({ dir: tmp("store") });
  const d = store.put(png, "image/png");
  return { store, attachment: { ...d, name: "shot.png" } };
}

async function waitFor(pred: () => boolean, ms = 1000): Promise<void> {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (pred()) return;
    await new Promise((r) => setTimeout(r, 5));
  }
  throw new Error("timeout");
}

// ---------- ACP -------------------------------------------------------------

function pair(makeAgent: (conn: AgentConn) => Agent): AcpTransport {
  const c2a = new TransformStream<Uint8Array, Uint8Array>();
  const a2c = new TransformStream<Uint8Array, Uint8Array>();
  new AgentSideConnection(makeAgent, ndJsonStream(a2c.writable, c2a.readable));
  return { stream: ndJsonStream(c2a.writable, a2c.readable), onExit: () => {}, dispose: () => {} };
}

class RecordingAgent implements Agent {
  readonly prompts: PromptRequest[] = [];
  async initialize(_p: InitializeRequest) {
    return { protocolVersion: 1 as const, agentCapabilities: { loadSession: false } };
  }
  async newSession(_p: NewSessionRequest) {
    return { sessionId: "acp-sess-1" };
  }
  async authenticate() {
    return;
  }
  async prompt(p: PromptRequest): Promise<PromptResponse> {
    this.prompts.push(p);
    return { stopReason: "end_turn" };
  }
  async cancel() {
    return;
  }
}

async function acpHarness(cwd: string, store: MediaStore) {
  let agent!: RecordingAgent;
  const transport = pair(() => (agent = new RecordingAgent()));
  const adapter = new AcpAdapter({
    spec: { agent: "pi", command: "x" },
    connect: () => transport,
    media: store,
  });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));
  await adapter.start({ cwd, sessionId: "m1" });
  return { adapter, events, agentOf: () => agent };
}

test("ACP: an attachment is copied into the worktree and named in the prompt", async () => {
  const { store, attachment } = storedPng();
  const cwd = gitWorktree();
  const h = await acpHarness(cwd, store);

  await h.adapter.send({ text: "why is this misaligned?", attachments: [attachment] });
  await waitFor(() => h.agentOf().prompts.length > 0);

  const blocks = h.agentOf().prompts[0]!.prompt;
  const text = blocks.map((b) => (b.type === "text" ? b.text : "")).join("");
  assert.match(text, /^why is this misaligned\?/);
  assert.match(text, /Attached files:/);
  // The named path must exist and hold the bytes — a prompt naming a missing
  // file is worse than no attachment at all.
  const named = /- (\S+)/.exec(text)![1]!;
  assert.ok(named.includes(ATTACHMENTS_DIR), named);
  assert.deepEqual(readFileSync(named), png);
});

test("ACP: the user.message echo keeps the typed text and adds descriptors", async () => {
  const { store, attachment } = storedPng();
  const h = await acpHarness(gitWorktree(), store);

  await h.adapter.send({ text: "look at this", attachments: [attachment] });
  await waitFor(() => h.events.some((e) => e.kind === "user.message"));

  const payload = h.events.find((e) => e.kind === "user.message")!.payload as {
    text: string;
    attachments?: MediaAttachment[];
  };
  // NOT the suffixed prompt: the transcript shows what the user typed.
  assert.equal(payload.text, "look at this");
  assert.deepEqual(payload.attachments, [attachment]);
});

test("ACP: a text-only turn is byte-identical to before (no attachments key)", async () => {
  const { store } = storedPng();
  const h = await acpHarness(gitWorktree(), store);

  await h.adapter.send({ text: "plain turn" });
  await waitFor(() => h.agentOf().prompts.length > 0);

  assert.deepEqual(h.agentOf().prompts[0]!.prompt, [{ type: "text", text: "plain turn" }]);
  const payload = h.events.find((e) => e.kind === "user.message")!.payload as Record<string, unknown>;
  assert.deepEqual(payload, { text: "plain turn" });
});

test("ACP: an image-only turn still sends a prompt the agent can act on", async () => {
  const { store, attachment } = storedPng();
  const h = await acpHarness(gitWorktree(), store);

  await h.adapter.send({ text: "", attachments: [attachment] });
  await waitFor(() => h.agentOf().prompts.length > 0);

  const text = h.agentOf().prompts[0]!.prompt.map((b) => (b.type === "text" ? b.text : "")).join("");
  assert.match(text, /Attached files:/);
  assert.ok(text.trim().length > 0, "an empty prompt would be a wasted turn");
});

// ---------- codex -----------------------------------------------------------

/**
 * A controllable fake `codex app-server` (same shape as `codex.test.ts`'s):
 * records outgoing frames and auto-replies to the handshake + `turn/start` so
 * `send()` completes.
 */
function fakeAppServer() {
  let lineCb: (l: string) => void = () => {};
  const sent: { method?: string; id?: unknown; params?: unknown }[] = [];
  const feed = (obj: unknown) => lineCb(JSON.stringify(obj));
  const transport: CodexTransport = {
    send: (line) => {
      const msg = JSON.parse(line) as { method?: string; id?: unknown; params?: unknown };
      sent.push(msg);
      if (msg.method && msg.id !== undefined) {
        const result =
          msg.method === "initialize"
            ? { userAgent: "fake", codexHome: "/tmp" }
            : msg.method === "thread/start"
              ? { thread: { id: "th1" } }
              : msg.method === "turn/start"
                ? { turn: { id: "t1" } }
                // Answered so the adapter's model probe resolves immediately;
                // leaving it out costs ~15s of timeout per test.
                : msg.method === "model/list"
                  ? { data: [], nextCursor: null }
                  : undefined;
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
  return { sent, transport };
}

async function codexHarness(cwd: string, store: MediaStore) {
  const fake = fakeAppServer();
  const adapter = new CodexAppServerAdapter({
    connect: () => fake.transport,
    media: store,
  });
  const events: AdapterEvent[] = [];
  adapter.on("event", (e) => events.push(e));
  await adapter.start({ cwd, sessionId: "m1" });
  return { adapter, events, sent: fake.sent };
}

test("codex: turn/start input names the materialised file", async () => {
  const { store, attachment } = storedPng();
  const cwd = gitWorktree();
  const h = await codexHarness(cwd, store);

  await h.adapter.send({ text: "explain this screenshot", attachments: [attachment] });
  await waitFor(() => h.sent.some((m) => m.method === "turn/start"));

  const params = h.sent.find((m) => m.method === "turn/start")!.params as {
    input: { type: string; text: string }[];
  };
  assert.equal(params.input.length, 1, "still one text element — no image element type");
  assert.match(params.input[0]!.text, /^explain this screenshot/);
  assert.match(params.input[0]!.text, /Attached files:/);
  const named = /- (\S+)/.exec(params.input[0]!.text)![1]!;
  assert.deepEqual(readFileSync(named), png);
});

test("codex: the echo keeps the typed text and adds descriptors", async () => {
  const { store, attachment } = storedPng();
  const h = await codexHarness(gitWorktree(), store);

  await h.adapter.send({ text: "here", attachments: [attachment] });
  await waitFor(() => h.events.some((e) => e.kind === "user.message"));

  const payload = h.events.find((e) => e.kind === "user.message")!.payload as {
    text: string;
    attachments?: MediaAttachment[];
  };
  assert.equal(payload.text, "here");
  assert.deepEqual(payload.attachments, [attachment]);
});

test("codex: a text-only turn keeps today's exact payload", async () => {
  const { store } = storedPng();
  const h = await codexHarness(gitWorktree(), store);

  await h.adapter.send({ text: "plain" });
  await waitFor(() => h.sent.some((m) => m.method === "turn/start"));

  const params = h.sent.find((m) => m.method === "turn/start")!.params as Record<string, unknown>;
  assert.deepEqual(params.input, [{ type: "text", text: "plain", text_elements: [] }]);
  const payload = h.events.find((e) => e.kind === "user.message")!.payload as Record<string, unknown>;
  assert.deepEqual(payload, { text: "plain" });
});

// ---------- no worktree -----------------------------------------------------

test("an attachment with no writable worktree surfaces session.error, never a silent drop", async () => {
  // The composer is supposed to prevent this (spec §5.5), but if it ever gets
  // through, the user must be told rather than watching the agent answer a
  // question about an image it never received.
  const { store, attachment } = storedPng();
  const h = await acpHarness(gitWorktree(), store);
  // Point the adapter at a path UNDER A REGULAR FILE: `mkdirSync` then fails with
  // ENOTDIR for every user, including root. A non-existent root directory would
  // not do — root can create it, and the test would silently stop testing
  // anything in a CI container.
  const blocker = join(tmp("blocked"), "not-a-directory");
  writeFileSync(blocker, "x");
  (h.adapter as unknown as { workspaceRoot: string }).workspaceRoot = join(
    blocker,
    "deny",
  );

  await h.adapter.send({ text: "look", attachments: [attachment] });
  await waitFor(() => h.events.some((e) => e.kind === "session.error"));

  const err = h.events.find((e) => e.kind === "session.error")!.payload as { message: string };
  assert.match(err.message, /attachment/i);
  assert.equal(h.agentOf().prompts.length, 0, "the turn must not be sent without the image");
});


// ---------- prepareTurnOrFail ------------------------------------------------
//
// The failure path — "the image could not be delivered, so abandon the turn" —
// was open-coded identically in all three adapters and asserted by nothing. It
// now lives in one function, and here is that assertion.

test("prepareTurnOrFail returns the turn when delivery succeeds", () => {
  const { store, attachment } = storedPng();
  const emitted: AdapterEvent[] = [];
  const turn = prepareTurnOrFail(
    store,
    { text: "look", attachments: [attachment] },
    gitWorktree(),
    (e) => emitted.push(e),
  );
  assert.ok(turn, "a deliverable turn is returned");
  assert.match(turn.promptText, /Attached files:/);
  assert.deepEqual(emitted, [], "nothing is emitted on the happy path");
});

test("prepareTurnOrFail abandons the turn with a session.error", () => {
  const { store, attachment } = storedPng();
  const emitted: AdapterEvent[] = [];
  // No worktree → nowhere to write the file. Sending anyway would prompt the
  // agent about a path that does not exist, which is worse than an error.
  const turn = prepareTurnOrFail(
    store,
    { text: "look", attachments: [attachment] },
    undefined,
    (e) => emitted.push(e),
  );
  assert.equal(turn, null, "the caller must not send this turn");
  assert.equal(emitted.length, 1);
  assert.equal(emitted[0].kind, "session.error");
  assert.match(
    String((emitted[0].payload as { message: string }).message),
    /attachment delivery failed: .*no worktree/,
  );
});

test("prepareTurnOrFail emits nothing for a text-only turn without a worktree", () => {
  // A session with no worktree can still hold a normal conversation: only
  // attachment delivery needs somewhere to write.
  const { store } = storedPng();
  const emitted: AdapterEvent[] = [];
  const turn = prepareTurnOrFail(store, { text: "hi" }, undefined, (e) => emitted.push(e));
  assert.equal(turn?.promptText, "hi");
  assert.deepEqual(emitted, []);
});
