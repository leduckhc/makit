#!/usr/bin/env tsx
/**
 * Throwaway end-to-end check for SPEC-assistant-display-media media (feat/multimodal).
 *
 * Runs the REAL makit server + REAL pi-acp (real model), drives one turn that
 * makes the agent read an image, and then verifies the phone-side contract:
 * an `agent.media` event arrives, `/media/<id>` serves bytes whose sha256 IS
 * the mediaId, and the same URL is refused without the paired bearer.
 */
import { mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { createHash } from "node:crypto";
import { request } from "node:https";
import WebSocket from "ws";

import { SessionManager } from "../src/manager.js";
import { startWsServer } from "../src/server.js";
import { loadOrCreateCert } from "../src/pairing/cert.js";
import { DeviceRegistry, type PairedDevice } from "../src/pairing/registry.js";

const PORT = 9788;
const BEARER = "media-e2e-token";
const PROJECT = process.argv[2] ?? process.cwd();
const IMAGE = process.argv[3] ?? "/tmp/probe-shot.png";

const home = resolve(tmpdir(), `makit-media-e2e-${PORT}`);
process.env.MAKIT_HOME = home;
mkdirSync(home, { recursive: true });
const device: PairedDevice = {
  id: "media-e2e",
  label: "probe",
  bearer: BEARER,
  pairedAt: Date.now(),
  lastSeenAt: Date.now(),
};
writeFileSync(resolve(home, "devices.json"), JSON.stringify([device], null, 2), { mode: 0o600 });

/** GET /media/<id>, optionally with the bearer. Resolves {status, body}. */
function fetchMedia(id: string, bearer?: string): Promise<{ status: number; body: Buffer }> {
  return new Promise((res, rej) => {
    const req = request(
      {
        host: "127.0.0.1",
        port: PORT,
        path: `/media/${id}`,
        method: "GET",
        // The app pins by fingerprint; this probe only checks route + auth.
        rejectUnauthorized: false,
        headers: bearer ? { Authorization: `Bearer ${bearer}` } : {},
      },
      (r) => {
        const chunks: Buffer[] = [];
        r.on("data", (c) => chunks.push(c as Buffer));
        r.on("end", () => res({ status: r.statusCode ?? 0, body: Buffer.concat(chunks) }));
      },
    );
    req.on("error", rej);
    req.end();
  });
}

async function main() {
  const cert = await loadOrCreateCert();
  const manager = new SessionManager({ projects: [PROJECT] });
  const ws = startWsServer({ host: "127.0.0.1", port: PORT, manager, cert, registry: new DeviceRegistry() });
  await manager.ensureDefaultSessions();
  await new Promise<void>((r) => (ws.https.listening ? r() : ws.https.once("listening", () => r())));

  const sock = new WebSocket(`wss://127.0.0.1:${PORT}`, { rejectUnauthorized: false });
  const send = (o: unknown) => sock.send(JSON.stringify(o));
  let sessionId = "";
  let mediaPayload: Record<string, any> | undefined;
  let finalText = "";
  // pi emits a banner `agent.message` before the turn even starts, so the turn
  // is only over when the status returns to idle after having gone running.
  let sawRunning = false;

  const done = new Promise<void>((resolveDone) => {
    sock.on("open", () => send({ v: 1, t: "hello", id: "h1", bearer: BEARER }));
    sock.on("message", (raw) => {
      const env = JSON.parse(String(raw));
      if (env.t === "hello.ack") return;
      if (env.t === "event" && env.event?.kind) {
        const { kind, payload } = env.event;
        if (kind === "agent.media") {
          mediaPayload = payload;
          console.log(`\n[event] agent.media ${JSON.stringify(payload)}`);
        } else if (kind === "agent.message") {
          finalText = payload.text;
          console.log(`\n[event] agent.message: ${JSON.stringify(payload.text).slice(0, 200)}`);
        } else if (kind === "session.status") {
          console.log(`[event] session.status ${payload.status}`);
          if (payload.status === "running") sawRunning = true;
          else if (sawRunning && payload.status !== "running") resolveDone();
        } else if (kind === "tool.call.start") {
          console.log(`[event] tool.call.start ${payload.name}`);
        } else if (kind === "session.error") {
          console.log(`[event] session.error ${JSON.stringify(payload)}`);
          resolveDone();
        }
        return;
      }
      // sessions.snapshot → grab a session and prompt it.
      const sessions = env.sessions ?? env.body?.sessions;
      if (Array.isArray(sessions) && sessions.length > 0 && !sessionId) {
        sessionId = sessions[0].id;
        console.log(`[probe] session ${sessionId} (agent=${sessions[0].agent})`);
        send({ v: 1, t: "sub", id: "s1", sessionId, fromSeq: 0 });
        send({
          v: 1,
          t: "cmd",
          id: "c1",
          kind: "send.message",
          sessionId,
          text: `Use your read tool on ${IMAGE}, then in your reply say one short sentence about it and display the image with markdown so I can see it. Do not use bash.`,
        });
      }
    });
  });

  await Promise.race([done, new Promise((r) => setTimeout(r, 180_000))]);

  console.log("\n==== verification ====");
  let failures = 0;
  const check = (ok: boolean, label: string) => {
    console.log(`${ok ? "PASS" : "FAIL"}  ${label}`);
    if (!ok) failures++;
  };

  check(!!mediaPayload, "an agent.media event reached the phone socket");
  if (mediaPayload) {
    const id = mediaPayload.mediaId as string;
    const authed = await fetchMedia(id, BEARER);
    check(authed.status === 200, `GET /media/<id> with bearer → 200 (got ${authed.status})`);
    const digest = createHash("sha256").update(authed.body).digest("hex");
    check(digest === id, "served bytes hash to the mediaId (content-addressed)");
    // NOT necessarily the file on disk: pi downscales a large image before
    // handing it to the model, so the tool-result blob is a *derived* copy
    // (observed: a 6.3MB full-page screenshot arrived as 242KB). Byte identity
    // is only expected when the harness passed the original through.
    const source = readFileSync(IMAGE);
    if (authed.body.length === source.length) {
      check(authed.body.equals(source), "served bytes are byte-identical to the source file");
    } else {
      console.log(
        `INFO  the harness re-encoded the image: ${source.length}B on disk → ${authed.body.length}B served`,
      );
    }
    const anon = await fetchMedia(id, undefined);
    check(anon.status === 401, `GET /media/<id> without bearer → 401 (got ${anon.status})`);
    const missing = await fetchMedia("f".repeat(64), BEARER);
    check(missing.status === 404, `GET /media/<unknown> → 404 (got ${missing.status})`);
    check(
      JSON.parse(missing.body.toString()).error === "media_not_found",
      "404 body is the JSON contract, not an image",
    );
  }
  // The markdown rewrite only applies when the agent actually used image
  // markdown, so report rather than assert.
  const inlineIds = [...finalText.matchAll(/makit-media:([a-f0-9]{64})/g)].map((m) => m[1]!);
  if (inlineIds.length === 0) {
    console.log(
      `INFO  no markdown image in the reply (nothing to rewrite): ${JSON.stringify(finalText).slice(0, 160)}`,
    );
  } else {
    check(true, "the final message carries a makit-media: URI (markdown rewrite)");
    // The prose path ingests the file itself (not a harness-derived copy), so
    // this is where a multi-MB original round-trips through the route.
    for (const id of inlineIds) {
      const res = await fetchMedia(id, BEARER);
      check(res.status === 200, `inline media ${id.slice(0, 8)}… serves 200 (got ${res.status})`);
      check(
        createHash("sha256").update(res.body).digest("hex") === id,
        `inline media ${id.slice(0, 8)}… hashes to its id (${res.body.length}B)`,
      );
      if (id !== mediaPayload?.mediaId) {
        check(
          res.body.equals(readFileSync(IMAGE)),
          `inline media ${id.slice(0, 8)}… is the original file byte-for-byte`,
        );
      }
    }
  }

  console.log(`\n${failures === 0 ? "ALL CHECKS PASSED" : `${failures} CHECK(S) FAILED`}`);
  process.exit(failures === 0 ? 0 : 1);
}

void main();
