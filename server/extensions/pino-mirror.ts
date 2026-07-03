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
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { WebSocket } from "ws";
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
  const host = loadHost();
  if (!host) return; // pino isn't running — behave as a normal pi.

  const ws = new WebSocket(host.url, { rejectUnauthorized: false });
  let sessionId = "";
  const outbox: Json[] = []; // events buffered until host.open acks

  const raw = (o: Json) => {
    if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(o));
  };
  // Send an AdapterEvent (or flush it later once we have a sessionId).
  const emit = (kind: string, payload: Json) => {
    const frame: Json = { v: 1, t: "cmd", id: `he-${Date.now()}-${Math.random()}`, kind: "host.event", ev: { ts: Date.now(), kind, payload } };
    if (sessionId) {
      frame.sessionId = sessionId;
      raw(frame);
    } else {
      outbox.push(frame);
    }
  };
  const status = (s: "idle" | "running") => {
    if (sessionId) raw({ v: 1, t: "cmd", id: `hs-${Date.now()}`, kind: "host.status", sessionId, status: s });
  };

  ws.on("open", () => {
    raw({ v: 1, t: "hello", id: "h", host: host.token });
  });
  ws.on("message", (buf: Buffer) => {
    let m: Json;
    try {
      m = JSON.parse(buf.toString());
    } catch {
      return;
    }
    if (m.t === "hello.ack") {
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
      return;
    }
    // Phone → pi: inject as a real user prompt into this live session.
    if (m.t === "host.prompt" && typeof m.text === "string") {
      pi.sendUserMessage(m.text, { deliverAs: "steer" });
    }
  });
  ws.on("error", () => {});

  // ---- pi events → pino chat --------------------------------------------

  // Per-content-index streamed-message ids, mirroring pino's PiAdapter.
  const msgIds = new Map<number, string>();

  pi.on("input", (e) => {
    if (typeof e.text === "string" && e.text) emit("user.message", { text: e.text });
  });

  pi.on("turn_start", () => status("running"));
  pi.on("turn_end", () => status("idle"));
  pi.on("agent_end", () => status("idle"));

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
    if (sessionId) raw({ v: 1, t: "cmd", id: "close", kind: "host.close", sessionId });
    ws.close();
  });
}
