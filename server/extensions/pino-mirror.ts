/**
 * pino-mirror — a pi extension that mirrors THIS pi session to pino (World D).
 *
 * Load it into your real pi (TUI or otherwise):
 *     pi -e /path/to/server/extensions/pino-mirror.ts
 *
 * It connects to the running pino server (endpoint + token from ~/.pino/host.json),
 * opens a "host" session, forwards pi's own agent events (streaming deltas, tool
 * calls, thinking, status) to the phone as structured chat, and injects the
 * phone's messages back via pi.sendUserMessage. No file tailing, no send-keys —
 * this is pino's transparent UI transport applied to a user-launched pi.
 *
 * Auth: ~/.pino/host.json {url, token} (written 0600 by `pino serve`).
 */
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { WebSocket } from "ws";
import { Type } from "typebox";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

type Json = Record<string, unknown>;

function loadHost(): { url: string; token: string } | undefined {
  try {
    const o = JSON.parse(readFileSync(join(homedir(), ".pino", "host.json"), "utf8"));
    if (typeof o?.url === "string" && typeof o?.token === "string") {
      return { url: o.url, token: o.token };
    }
  } catch {
    /* pino not running / no host file */
  }
  return undefined;
}

function classifyRisk(name: string): "safe" | "risky" | "destructive" {
  return name === "edit" || name === "write" || name === "bash" ? "risky" : "safe";
}

export default function (pi: ExtensionAPI): void {
  // Skip pino's OWN spawned pi (it already talks to pino directly) — otherwise
  // an auto-loaded copy would recursively mirror pino's sessions back to pino.
  if (process.env.PINO_BRIDGE_URL) return;
  // NOTE: we do NOT bail when pino is down at load — connect() retries and
  // re-reads host.json each attempt, so we survive pino starting later and
  // token rotation across pino restarts. The ask tool still registers below
  // (falling back to pi's TUI when no phone is connected).

  let ws: WebSocket | null = null;
  let sessionId = "";
  let closing = false; // set on pi shutdown — stop reconnecting
  let backoff = 1000; // reconnect delay, grows to a cap, resets on connect
  let reconnectTimer: ReturnType<typeof setTimeout> | undefined;
  const outbox: Json[] = []; // events buffered until a host session is open
  const OUTBOX_MAX = 1000;
  const pendingAsks = new Map<string, (r: Json) => void>(); // askId → resolver
  // Latest ExtensionContext captured from event handlers, used to invoke
  // context-scoped SDK calls (e.g. ctx.compact()) when the phone sends a
  // built-in control action. pi.setThinkingLevel lives on `pi` directly.
  let lastCtx: ExtensionContext | undefined;

  // Phone → pi: run a built-in control action via the pi SDK. These are NOT
  // user turns — they never reach the LLM as a prompt.
  function runAction(action: string, args?: Json): void {
    if (action === "compact") {
      lastCtx?.compact();
    } else if (action === "thinking") {
      const level = typeof args?.level === "string" ? args.level : undefined;
      const valid = ["off", "minimal", "low", "medium", "high", "xhigh"];
      if (level && valid.includes(level)) {
        pi.setThinkingLevel(level as never);
        emitMeta();
      }
    } else if (action === "model") {
      const provider = typeof args?.provider === "string" ? args.provider : undefined;
      const id = typeof args?.id === "string" ? args.id : undefined;
      const model =
        provider && id ? lastCtx?.modelRegistry.find(provider, id) : undefined;
      if (model) void pi.setModel(model).then(() => emitMeta());
    }
  }

  // Whether the initial meta frame has been pushed for this pi process.
  let metaSent = false;

  // Push current model + thinking level + selectable models to the phone so it
  // can show a subtle indicator and populate the /model picker. Model info is
  // ctx-scoped; thinking level lives on `pi` directly.
  function emitMeta(): void {
    const m = lastCtx?.model;
    const models = (lastCtx?.modelRegistry.getAvailable() ?? []).map((x) => ({
      provider: x.provider,
      id: x.id,
      name: x.name,
    }));
    metaSent = true;
    emit("session.meta", {
      model: m ? { provider: m.provider, id: m.id, name: m.name } : null,
      thinking: pi.getThinkingLevel(),
      models,
    });
  }

  // Capture the latest ctx from event handlers; emit meta once we first have it.
  function noteCtx(ctx: ExtensionContext): void {
    lastCtx = ctx;
    if (!metaSent) emitMeta();
  }

  const raw = (o: Json) => {
    if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(o));
  };
  // Send an AdapterEvent (or buffer it until a host session is open).
  const emit = (kind: string, payload: Json) => {
    const frame: Json = { v: 1, t: "cmd", id: `he-${Date.now()}-${Math.random()}`, kind: "host.event", ev: { ts: Date.now(), kind, payload } };
    if (sessionId) {
      frame.sessionId = sessionId;
      raw(frame);
    } else {
      if (outbox.length >= OUTBOX_MAX) outbox.shift();
      outbox.push(frame);
    }
  };
  const status = (s: "idle" | "running") => {
    if (sessionId) raw({ v: 1, t: "cmd", id: `hs-${Date.now()}`, kind: "host.status", sessionId, status: s });
  };

  // (Re)connect to pino. On drop, retry with capped backoff so a pino restart
  // (or transient blip) re-establishes the mirror without restarting pi.
  function connect(): void {
    if (closing) return;
    const host = loadHost();
    if (!host) {
      // pino not up yet — retry later.
      reconnectTimer = setTimeout(connect, backoff);
      backoff = Math.min(backoff * 2, 15000);
      return;
    }
    const sock = new WebSocket(host.url, { rejectUnauthorized: false });
    ws = sock;
    sock.on("open", () => {
      raw({ v: 1, t: "hello", id: "h", host: host.token });
    });
    sock.on("message", (buf: Buffer) => {
      let m: Json;
      try {
        m = JSON.parse(buf.toString());
      } catch {
        return;
      }
      if (m.t === "hello.ack") {
        backoff = 1000; // healthy connection — reset backoff
        raw({
          v: 1,
          t: "cmd",
          id: "open",
          kind: "host.open",
          title: pi.getSessionName?.() ?? "pi (mirror)",
          cwd: process.cwd(),
        });
        return;
      }
      if (m.id === "open" && m.t === "ack" && typeof m.sessionId === "string") {
        sessionId = m.sessionId;
        for (const f of outbox.splice(0)) {
          f.sessionId = sessionId;
          raw(f);
        }
        // A fresh subscriber (or reconnect after a pino restart that dropped the
        // replay log) needs current meta re-sent.
        if (lastCtx) emitMeta();
        return;
      }
      // Phone → pi: inject as a real user prompt into this live session.
      if (m.t === "host.prompt" && typeof m.text === "string") {
        pi.sendUserMessage(m.text, { deliverAs: "steer" });
        return;
      }
      // Phone → pi: run a built-in control action (compact, thinking).
      if (m.t === "host.action" && typeof m.action === "string") {
        runAction(m.action, m.args as Json | undefined);
        return;
      }
      // Answer to an askUserQuestion we routed to the phone.
      if (m.t === "host.ask.result" && typeof m.id === "string") {
        pendingAsks.get(m.id)?.(m);
        pendingAsks.delete(m.id);
      }
    });
    sock.on("error", () => {});
    sock.on("close", () => {
      if (ws === sock) ws = null;
      sessionId = "";
      // Fail any in-flight asks so the tool doesn't hang forever.
      for (const resolve of pendingAsks.values()) resolve({ cancelled: true });
      pendingAsks.clear();
      if (!closing) {
        reconnectTimer = setTimeout(connect, backoff);
        backoff = Math.min(backoff * 2, 15000);
      }
    });
  }

  // ---- ask the phone (route askUserQuestion to the app dialog) -----------

  const questionsParam = Type.Object({
    questions: Type.Array(
      Type.Object({
        header: Type.Optional(Type.String()),
        question: Type.String(),
        options: Type.Array(
          Type.Object({
            label: Type.String(),
            description: Type.Optional(Type.String()),
          }),
        ),
        multi: Type.Optional(Type.Boolean()),
        recommended: Type.Optional(Type.Integer()),
      }),
    ),
  });

  type AskQ = { question: string; options?: { label: string }[] };

  async function askViaPhone(questions: AskQ[]): Promise<string[]> {
    const askId = `ask-${Date.now()}-${Math.random()}`;
    const resp = await new Promise<Json>((resolve) => {
      pendingAsks.set(askId, resolve);
      raw({ v: 1, t: "cmd", id: askId, kind: "host.ask", sessionId, askId, questions });
      setTimeout(() => {
        if (pendingAsks.delete(askId)) resolve({ cancelled: true });
      }, 5 * 60 * 1000);
    });
    return Array.isArray(resp.answers) ? (resp.answers as string[]) : [];
  }

  // Full ask provider: route to the phone when a pino session is live, else
  // fall back to pi's own TUI dialog — so this cleanly replaces @mammothb/pi-ask.
  const askExecute = async (
    _id: string,
    params: { questions: AskQ[] },
    _signal: unknown,
    _onUpdate: unknown,
    ctx: { ui: { select(t: string, o: string[]): Promise<string | undefined> } },
  ) => {
    const questions = Array.isArray(params.questions) ? params.questions : [];
    let answers: string[];
    if (sessionId) {
      answers = await askViaPhone(questions);
    } else {
      answers = [];
      for (const q of questions) {
        const opts = (q.options ?? []).map((o) => o.label);
        answers.push((await ctx.ui.select(q.question, opts)) ?? "");
      }
    }
    const lines = questions.map((q, i) => `Q: ${q.question}\nA: ${answers[i] ?? "(no answer)"}`);
    return { content: [{ type: "text", text: lines.join("\n\n") }] };
  };

  // Register both casings so the model reaches it whichever it emits.
  for (const name of ["AskUserQuestion", "askUserQuestion"]) {
    pi.registerTool({
      name,
      label: "Ask the user",
      description:
        "Ask the user one or more multiple-choice questions (on their phone when pino is connected, else in the terminal) and wait for the answers. 1–4 questions, each with 2–4 options.",
      parameters: questionsParam,
      execute: askExecute as never,
    });
  }

  // ---- pi events → pino chat --------------------------------------------

  // Per-content-index streamed-message ids, mirroring pino's PiAdapter.
  const msgIds = new Map<number, string>();

  pi.on("input", (e, ctx) => {
    noteCtx(ctx);
    if (typeof e.text === "string" && e.text) emit("user.message", { text: e.text });
  });

  pi.on("turn_start", (_e, ctx) => {
    noteCtx(ctx);
    status("running");
  });
  pi.on("turn_end", (_e, ctx) => {
    noteCtx(ctx);
    status("idle");
  });
  pi.on("agent_end", () => status("idle"));

  // Keep the phone's model/thinking indicator in sync with TUI-side changes.
  pi.on("model_select", (_e, ctx) => {
    lastCtx = ctx;
    emitMeta();
  });
  pi.on("thinking_level_select", (_e, ctx) => {
    lastCtx = ctx;
    emitMeta();
  });

  pi.on("message_update", (e) => {
    const ame = e.assistantMessageEvent as any;
    if (!ame || typeof ame !== "object") return;
    const idx: number = typeof ame.contentIndex === "number" ? ame.contentIndex : 0;
    if (ame.type === "text_start") {
      msgIds.set(idx, `am-${Date.now()}-${idx}`);
    } else if (ame.type === "text_delta") {
      const chunk = typeof ame.delta === "string" ? ame.delta : "";
      const msgId = msgIds.get(idx);
      if (msgId && chunk) emit("agent.message.delta", { msgId, chunk });
    } else if (ame.type === "text_end") {
      const text = typeof ame.content === "string" ? ame.content : "";
      const msgId = msgIds.get(idx);
      msgIds.delete(idx);
      if (text) emit("agent.message", { text, ...(msgId ? { msgId } : {}) });
    } else if (ame.type === "thinking_end") {
      const text = typeof ame.content === "string" ? ame.content : "";
      if (text.trim()) emit("agent.thinking", { text });
    }
  });

  pi.on("tool_execution_start", (e) => {
    const name = String(e.toolName ?? "tool");
    emit("tool.call.start", {
      callId: String(e.toolCallId ?? `c-${Date.now()}`),
      name,
      args: e.args ?? {},
      risk: classifyRisk(name),
    });
  });

  pi.on("tool_execution_end", (e) => {
    const out = typeof e.result === "string" ? e.result : JSON.stringify(e.result ?? "");
    emit("tool.call.end", {
      callId: String(e.toolCallId ?? ""),
      exitCode: e.isError ? 1 : 0,
      summary: (out.split("\n").find((l) => l.trim()) ?? "").slice(0, 120),
      output: out,
    });
  });

  pi.on("session_shutdown", () => {
    closing = true;
    if (reconnectTimer) clearTimeout(reconnectTimer);
    if (sessionId) raw({ v: 1, t: "cmd", id: "close", kind: "host.close", sessionId });
    ws?.close();
  });

  connect(); // kick off the (reconnecting) connection
}
