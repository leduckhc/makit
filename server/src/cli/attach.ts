/**
 * `makit attach` — a terminal client for a makit-managed session.
 *
 * It connects to the running makit server exactly like the mobile app does
 * (WSS + bearer), subscribes to one session, renders its event stream, and
 * sends typed lines as `send.message`. Because the terminal and the app are
 * both plain subscribers of the SAME makit-managed pi process, everything is
 * live in both directions — type in the terminal, see it on the phone, and
 * vice-versa — with no second pi process fighting over the session file.
 *
 * Auth: reuses a paired device bearer from ~/.makit/devices.json. `makit attach`
 * runs on the same host as the server, so reading that file is no weaker than
 * the trust the local user already has.
 */
import { WebSocket } from "ws";
import { createInterface, type Interface } from "node:readline";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { renderEvent, type RenderState } from "./render.js";

interface AttachArgs {
  host: string;
  port: number;
  sessionId?: string;
  spawn: boolean;
  projectId?: string;
}

function parseAttachArgs(argv: string[]): AttachArgs {
  const a: AttachArgs = { host: "127.0.0.1", port: 8787, spawn: false };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i]!;
    if (t === "--port") a.port = Number(argv[++i]);
    else if (t === "--host") a.host = String(argv[++i]);
    else if (t === "--new") a.spawn = true;
    else if (t === "--project") a.projectId = String(argv[++i]);
    else if (!t.startsWith("--")) a.sessionId = t;
  }
  return a;
}

export function readBearer(): string {
  const f = join(homedir(), ".makit", "devices.json");
  let arr: unknown;
  try {
    arr = JSON.parse(readFileSync(f, "utf8"));
  } catch {
    throw new Error(`could not read ${f} — pair the app first`);
  }
  if (!Array.isArray(arr) || arr.length === 0) {
    throw new Error("no paired devices — pair the app first, then retry");
  }
  const bearer = (arr[0] as { bearer?: string }).bearer;
  if (!bearer) throw new Error("no bearer in devices.json");
  return bearer;
}

interface SessionDTO {
  id: string;
  title: string;
  status: string;
  projectId: string;
  agent: string;
}
interface ProjectDTO {
  id: string;
  name: string;
}

export async function runAttach(argv: string[]): Promise<void> {
  const args = parseAttachArgs(argv);
  const bearer = readBearer();
  const ws = new WebSocket(`wss://${args.host}:${args.port}`, {
    rejectUnauthorized: false,
  });

  let st: RenderState = {};
  let sessions: SessionDTO[] = [];
  let projects: ProjectDTO[] = [];
  let currentSid: string | undefined = args.sessionId;
  let subscribed = false;
  let choosing = false; // guards against re-entrant snapshot-driven selection
  let quitting = false; // true once the user asked to quit (clean exit)
  let prompting = false; // true while answering a server UI request
  let promptChain: Promise<void> = Promise.resolve(); // serialize srv.requests
  const rl: Interface = createInterface({ input: process.stdin, output: process.stdout });

  const send = (o: unknown) => {
    if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(o));
  };
  const ask = (q: string): Promise<string> =>
    new Promise((resolve) => rl.question(q, resolve));
  const C = {
    reset: "\x1b[0m",
    dim: "\x1b[2m",
    cyan: "\x1b[36m",
    yellow: "\x1b[33m",
  };
  const s = (v: unknown) => (typeof v === "string" ? v : v == null ? "" : String(v));

  ws.on("open", () => send({ v: 1, t: "hello", id: "h", bearer }));
  ws.on("error", (e: Error) => {
    console.error(`[makit] connection error: ${e.message}`);
    process.exit(1);
  });
  ws.on("close", () => {
    console.log("\n[makit] disconnected.");
    process.exit(quitting ? 0 : 1);
  });

  ws.on("message", (buf: Buffer) => {
    let m: Record<string, unknown>;
    try {
      m = JSON.parse(buf.toString());
    } catch {
      return;
    }
    if (m.kind === "projects.snapshot") {
      projects = (m.projects as ProjectDTO[]) ?? [];
      return;
    }
    if (m.kind === "sessions.snapshot") {
      sessions = (m.sessions as SessionDTO[]) ?? [];
      if (!subscribed && !choosing) void chooseAndSubscribe();
      return;
    }
    if (m.t === "event" && m.kind === "session.event" && m.event) {
      const e = m.event as import("../protocol.js").SessionEvent;
      if (currentSid && e.sessionId !== currentSid) return;
      const r = renderEvent(e, st);
      st = r.st;
      if (r.out) process.stdout.write(r.out);
      return;
    }
    if (m.t === "srv.request") {
      // Serialize prompts: readline has one pending question at a time, so a
      // second srv.request must wait for the first to be answered.
      promptChain = promptChain.then(() => handleSrvRequest(m));
      return;
    }
    // The session.spawn ack carries { sessionId } — subscribe to it.
    if (m.t === "ack" && m.id === "spawn" && !subscribed && typeof m.sessionId === "string") {
      doSubscribe(m.sessionId);
    }
  });

  async function chooseAndSubscribe(): Promise<void> {
    choosing = true; // block re-entry from further sessions.snapshot frames
    if (currentSid) return doSubscribe(currentSid);

    if (args.spawn) {
      const pid = args.projectId ?? projects[0]?.id;
      if (!pid) {
        console.error("[makit] no project to spawn into.");
        process.exit(1);
      }
      console.log("[makit] spawning a new session…");
      send({ v: 1, t: "cmd", id: "spawn", kind: "session.spawn", projectId: pid });
      return; // subscribe happens on the spawn ack
    }

    if (sessions.length === 0) {
      console.log("[makit] no sessions. Start one with `makit attach --new`, or from the app.");
      process.exit(0);
    }
    if (sessions.length === 1) return doSubscribe(sessions[0]!.id);

    console.log("\nSessions:");
    sessions.forEach((s, i) => {
      const proj = projects.find((p) => p.id === s.projectId)?.name ?? "";
      console.log(`  ${i + 1}. ${s.title}  [${s.status}]  ${proj}  (${s.id.slice(0, 8)})`);
    });
    rl.question("Pick a session #: ", (ans) => {
      const s = sessions[Number(ans.trim()) - 1];
      if (!s) {
        console.error("[makit] invalid selection.");
        process.exit(1);
      }
      doSubscribe(s.id);
    });
  }

  function doSubscribe(sid: string): void {
    currentSid = sid;
    subscribed = true;
    send({ v: 1, t: "sub", id: "sub", sessionId: sid });
    const sess = sessions.find((x) => x.id === sid);
    console.log(
      `\n[makit] attached to "${sess?.title ?? sid}" — type to chat, Ctrl-C to quit.\n`,
    );
    rl.on("line", (line) => {
      if (prompting) return; // a UI request owns the input right now
      const text = line.trim();
      if (!text) return;
      send({
        v: 1,
        t: "cmd",
        id: `m-${Date.now()}`,
        kind: "send.message",
        sessionId: currentSid,
        text,
      });
    });
    rl.on("SIGINT", () => {
      quitting = true;
      ws.close();
      process.exit(0);
    });
  }

  /**
   * Answer a server UI request (askUserQuestion / confirmAction / input) from
   * the terminal, then send the matching `srv.response`. The first client to
   * respond wins, so the app can answer instead — whoever's fastest.
   */
  async function handleSrvRequest(env: Record<string, unknown>): Promise<void> {
    const id = s(env.id);
    const kind = s(env.kind);
    prompting = true;
    try {
      if (kind === "confirmAction") {
        process.stdout.write(`\n${C.yellow}▲ ${s(env.title)}${C.reset}\n  ${s(env.message)}\n`);
        if (env.action) process.stdout.write(`  ${C.dim}action: ${s(env.action)}${C.reset}\n`);
        if (env.preview) process.stdout.write(`  ${C.dim}${s(env.preview)}${C.reset}\n`);
        const a = (await ask("Approve? [y/N] ")).trim().toLowerCase();
        send({ v: 1, t: "srv.response", id, kind, approved: a === "y" || a === "yes" });
        return;
      }
      if (kind === "input") {
        process.stdout.write(`\n${C.cyan}? ${s(env.title)}${C.reset}\n`);
        const prefill = s(env.prefill);
        const a = await ask(`${prefill ? `[${prefill}] ` : ""}› `);
        const value = a.trim() === "" && prefill ? prefill : a;
        send({ v: 1, t: "srv.response", id, kind, value });
        return;
      }
      if (kind === "askUserQuestion") {
        const questions = Array.isArray(env.questions) ? env.questions : [];
        const indices: number[] = [];
        const answers: string[] = [];
        for (const q of questions as Record<string, unknown>[]) {
          if (q.header) process.stdout.write(`\n${C.cyan}? ${s(q.header)}${C.reset}\n`);
          process.stdout.write(`${s(q.question)}\n`);
          const opts = (Array.isArray(q.options) ? q.options : []) as Record<string, unknown>[];
          opts.forEach((o, i) => {
            const rec = q.recommended === i ? ` ${C.dim}(recommended)${C.reset}` : "";
            const desc = o.description ? ` — ${C.dim}${s(o.description)}${C.reset}` : "";
            process.stdout.write(`  ${i + 1}. ${s(o.label)}${rec}${desc}\n`);
          });
          const raw = (await ask("Pick #: ")).trim();
          let pick = Number.parseInt(raw, 10) - 1;
          if (!(pick >= 0 && pick < opts.length)) {
            pick = typeof q.recommended === "number" ? q.recommended : 0;
          }
          indices.push(pick);
          answers.push(s(opts[pick]?.label));
        }
        const resp: Record<string, unknown> = {
          v: 1,
          t: "srv.response",
          id,
          kind,
          indices,
          answers,
        };
        if (answers.length === 1) resp.answer = answers[0];
        send(resp);
        return;
      }
      // Unknown UI kind → decline so pi doesn't hang.
      send({ v: 1, t: "srv.response", id, kind, cancelled: true });
    } finally {
      prompting = false;
    }
  }
}
