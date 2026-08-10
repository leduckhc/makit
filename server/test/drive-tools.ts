/**
 * Drive the running keyless e2e server so the REAL app renders a tool turn.
 *
 * The app cannot produce tool rows on its own in the keyless loop: the stub
 * adapter's triggers are text-only (STREAM/THINK/ASK_*), which is why
 * `TOOLS` was added to `src/adapters/stub.ts`. This script connects to the
 * already-running server, finds a session, and prompts it — the app, subscribed
 * to the same session, renders the result live.
 *
 *   pnpm exec tsx test/drive-tools.ts [--text TOOLS]
 *
 * Not part of the test suite: a QA driver, alongside e2e-media.ts.
 */
import WebSocket from "ws";

const PORT = Number(process.env.MAKIT_QA_PORT ?? 9787);
const BEARER = process.env.MAKIT_QA_BEARER ?? "e2e-token";
const textArg = process.argv.indexOf("--text");
const TEXT = textArg > -1 ? String(process.argv[textArg + 1]) : "TOOLS";

const sock = new WebSocket(`wss://127.0.0.1:${PORT}`, { rejectUnauthorized: false });
const send = (o: unknown) => sock.send(JSON.stringify(o));

// A driver that hangs for 60 s with no output is worse than one that fails: the
// usual cause is simply that the server is not running.
sock.on("error", (err: Error) => {
  console.error(`[error] ${err.message}`);
  console.error(`        is the e2e server up on :${PORT}? (docs/DEVELOPMENT.md)`);
  process.exit(1);
});

let sessionId = "";
let sawRunning = false;
const started: string[] = [];
const ended: string[] = [];

const done = new Promise<void>((resolve) => {
  sock.on("open", () => send({ v: 1, t: "hello", id: "h1", bearer: BEARER }));
  sock.on("message", (raw) => {
    const env = JSON.parse(String(raw));
    if (env.t === "hello.ack") return;

    if (env.t === "event" && env.event?.kind) {
      const { kind, payload } = env.event;
      if (kind === "tool.call.start") {
        started.push(payload.name);
        console.log(`[start] ${payload.name} risk=${payload.risk}`);
      } else if (kind === "tool.call.end") {
        ended.push(payload.callId);
        console.log(`[end  ] exit=${payload.exitCode} ${payload.summary ?? ""}`);
      } else if (kind === "agent.thinking") {
        console.log("[think]", String(payload.text).slice(0, 60), "…");
      } else if (kind === "agent.message") {
        console.log("[reply]", String(payload.text).slice(0, 80));
      } else if (kind === "session.status") {
        console.log(`[status] ${payload.status}`);
        if (payload.status === "running") sawRunning = true;
        else if (sawRunning) resolve();
      }
      return;
    }

    const sessions = env.sessions ?? env.body?.sessions;
    if (Array.isArray(sessions) && sessions.length > 0 && !sessionId) {
      sessionId = sessions[0].id;
      console.log(`[probe] session ${sessionId} agent=${sessions[0].agent}`);
      send({ v: 1, t: "sub", id: "s1", sessionId, fromSeq: 0 });
      send({ v: 1, t: "cmd", id: "c1", kind: "send.message", sessionId, text: TEXT });
    }
  });
});

const outcome = await Promise.race([
  done.then(() => "turn finished"),
  new Promise((r) => setTimeout(() => r("TIMED OUT after 60s"), 60_000)),
]);
console.log(`\n${outcome}`);
console.log(`\nstarted=${started.length} ended=${ended.length} → ${started.join(", ")}`);
sock.close();
process.exit(started.length > 0 && started.length === ended.length ? 0 : 1);
