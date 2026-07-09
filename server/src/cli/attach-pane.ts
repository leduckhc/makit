/**
 * `makit attach --pane <target>` — mirror a herdr/tmux pane running a real pi
 * TUI, over the makit server. This is the POC of the multiplexer-bridge path:
 * the server polls the pane and streams frames; we render them and forward
 * keystrokes back via `pane.input` / `pane.key`.
 *
 * It renders the raw pane screen (ANSI), so this is a terminal mirror, not the
 * structured chat UI. Any client (the phone app, later) can do the same.
 */
import { WebSocket } from "ws";
import { readBearer } from "./attach.js";

interface PaneArgs {
  host: string;
  port: number;
  target: string;
}

function parsePaneArgs(argv: string[]): PaneArgs {
  const a: PaneArgs = { host: "127.0.0.1", port: 8787, target: "" };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i]!;
    if (t === "--port") a.port = Number(argv[++i]);
    else if (t === "--host") a.host = String(argv[++i]);
    else if (t === "--pane") a.target = String(argv[++i]);
  }
  return a;
}

export async function runPaneAttach(argv: string[]): Promise<void> {
  const args = parsePaneArgs(argv);
  if (!args.target) {
    console.error("[makit] usage: makit attach --pane <herdr-pane-id>");
    process.exit(2);
  }
  const bearer = readBearer();
  const ws = new WebSocket(`wss://${args.host}:${args.port}`, {
    rejectUnauthorized: false,
  });
  let quitting = false;
  const send = (o: unknown) => {
    if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(o));
  };

  ws.on("open", () => send({ v: 1, t: "hello", id: "h", bearer }));
  ws.on("error", (e: Error) => {
    console.error(`[makit] connection error: ${e.message}`);
    process.exit(1);
  });
  ws.on("close", () => {
    process.stdout.write("\x1b[?25h"); // restore cursor
    console.log("\n[makit] pane detached.");
    process.exit(quitting ? 0 : 1);
  });

  ws.on("message", (buf: Buffer) => {
    let m: Record<string, unknown>;
    try {
      m = JSON.parse(buf.toString());
    } catch {
      return;
    }
    if (m.t === "hello.ack") {
      send({ v: 1, t: "cmd", id: "pa", kind: "pane.attach", target: args.target });
      console.log(`[makit] mirroring pane ${args.target} — type + Enter to send, Ctrl-C to quit.\n`);
      return;
    }
    if (m.t === "event" && m.kind === "pane.frame" && m.target === args.target) {
      // Redraw: home the cursor + clear, then paint the pane's rendered screen.
      process.stdout.write("\x1b[H\x1b[2J" + String(m.data ?? ""));
    }
  });

  // Line-based input for the POC: send the text, then a real Enter key.
  const rl = (await import("node:readline")).createInterface({
    input: process.stdin,
    output: process.stdout,
  });
  rl.on("line", (line) => {
    send({ v: 1, t: "cmd", id: `pi-${Date.now()}`, kind: "pane.input", target: args.target, text: line });
    send({ v: 1, t: "cmd", id: `pk-${Date.now()}`, kind: "pane.key", target: args.target, keys: ["Enter"] });
  });
  rl.on("SIGINT", () => {
    quitting = true;
    send({ v: 1, t: "cmd", id: "pd", kind: "pane.detach", target: args.target });
    ws.close();
    process.exit(0);
  });
}
