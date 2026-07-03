/**
 * `pino attach` — a terminal client for a pino-managed session.
 *
 * It connects to the running pino server exactly like the mobile app does
 * (WSS + bearer), subscribes to one session, renders its event stream, and
 * sends typed lines as `send.message`. Because the terminal and the app are
 * both plain subscribers of the SAME pino-managed pi process, everything is
 * live in both directions — type in the terminal, see it on the phone, and
 * vice-versa — with no second pi process fighting over the session file.
 *
 * Auth: reuses a paired device bearer from ~/.pino/devices.json. `pino attach`
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

function readBearer(): string {
  const f = join(homedir(), ".pino", "devices.json");
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
  const rl: Interface = createInterface({ input: process.stdin, output: process.stdout });

  const send = (o: unknown) => ws.send(JSON.stringify(o));

  ws.on("open", () => send({ v: 1, t: "hello", id: "h", bearer }));
  ws.on("error", (e: Error) => {
    console.error(`[pino] connection error: ${e.message}`);
    process.exit(1);
  });
  ws.on("close", () => {
    console.log("\n[pino] disconnected.");
    process.exit(0);
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
      if (!subscribed) void chooseAndSubscribe();
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
    // spawn ack carries the new session
    if (m.t === "ack" && m.session && !subscribed) {
      const s = m.session as SessionDTO;
      sessions = [...sessions, s];
      doSubscribe(s.id);
    }
  });

  async function chooseAndSubscribe(): Promise<void> {
    if (currentSid) return doSubscribe(currentSid);

    if (args.spawn) {
      const pid = args.projectId ?? projects[0]?.id;
      if (!pid) {
        console.error("[pino] no project to spawn into.");
        process.exit(1);
      }
      console.log("[pino] spawning a new session…");
      send({ v: 1, t: "cmd", id: "spawn", kind: "session.spawn", projectId: pid });
      return; // subscribe happens on the spawn ack
    }

    if (sessions.length === 0) {
      console.log("[pino] no sessions. Start one with `pino attach --new`, or from the app.");
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
        console.error("[pino] invalid selection.");
        process.exit(1);
      }
      doSubscribe(s.id);
    });
  }

  function doSubscribe(sid: string): void {
    currentSid = sid;
    subscribed = true;
    send({ v: 1, t: "sub", id: "sub", sessionId: sid });
    const s = sessions.find((x) => x.id === sid);
    console.log(
      `\n[pino] attached to "${s?.title ?? sid}" — type to chat, Ctrl-C to quit.\n`,
    );
    rl.on("line", (line) => {
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
      ws.close();
      process.exit(0);
    });
  }
}
