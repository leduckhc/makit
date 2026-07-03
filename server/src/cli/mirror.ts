/**
 * `pino mirror --pane <id> [--session <path>] [--project <id>]`
 *
 * Tells the running pino server to mirror a real `pi` TUI in a multiplexer pane
 * (World B): the server tails that session's file → the phone sees a live chat,
 * and the phone's composer is injected into the pane via send-keys. This just
 * triggers the server-side mirror session (which persists) and prints its id;
 * you then drive it from the app. Keep using your pi TUI as normal.
 */
import { WebSocket } from "ws";
import { readBearer } from "./attach.js";

interface MirrorArgs {
  host: string;
  port: number;
  pane: string;
  sessionPath?: string;
  projectId?: string;
}

function parseArgs(argv: string[]): MirrorArgs {
  const a: MirrorArgs = { host: "127.0.0.1", port: 8787, pane: "" };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i]!;
    if (t === "--port") a.port = Number(argv[++i]);
    else if (t === "--host") a.host = String(argv[++i]);
    else if (t === "--pane") a.pane = String(argv[++i]);
    else if (t === "--session") a.sessionPath = String(argv[++i]);
    else if (t === "--project") a.projectId = String(argv[++i]);
  }
  return a;
}

export async function runMirror(argv: string[]): Promise<void> {
  const args = parseArgs(argv);
  if (!args.pane) {
    console.error("[pino] usage: pino mirror --pane <pane-id> [--session <path>] [--project <id>]");
    process.exit(2);
  }
  const bearer = readBearer();
  const ws = new WebSocket(`wss://${args.host}:${args.port}`, {
    rejectUnauthorized: false,
  });
  const send = (o: unknown) => ws.send(JSON.stringify(o));

  ws.on("open", () => send({ v: 1, t: "hello", id: "h", bearer }));
  ws.on("error", (e: Error) => {
    console.error(`[pino] connection error: ${e.message}`);
    process.exit(1);
  });
  ws.on("message", (buf: Buffer) => {
    let m: Record<string, unknown>;
    try {
      m = JSON.parse(buf.toString());
    } catch {
      return;
    }
    if (m.t === "hello.ack") {
      send({
        v: 1,
        t: "cmd",
        id: "mirror",
        kind: "session.mirror",
        pane: args.pane,
        ...(args.sessionPath ? { sessionPath: args.sessionPath } : {}),
        ...(args.projectId ? { projectId: args.projectId } : {}),
      });
      return;
    }
    if (m.id === "mirror" && m.t === "ack") {
      console.log(`[pino] mirroring pane ${args.pane} → session ${m.sessionId}.`);
      console.log("[pino] open the app to chat with it. Keep using your pi TUI as normal.");
      ws.close();
      process.exit(0);
    }
    if (m.id === "mirror" && m.t === "err") {
      console.error(`[pino] mirror failed: ${m.message}`);
      ws.close();
      process.exit(1);
    }
  });
}
