/**
 * T14 (SPEC-46) — `makit tail`: replay a session's events and (with `-f`) keep
 * streaming.
 *
 * Two contracts are pinned: `--since SEQ` replays from that cursor via
 * `sub {fromSeq}` and then streams; and `--json` is one `SessionEvent` per line,
 * byte-identical to the wire (D7) — human output goes through `renderEvent`.
 *
 * The hang trap (AGENTS/DEVELOPMENT): `node --test` has no per-test timeout, so
 * the `-f` test never awaits stream end. It drives the stream from events the
 * stub actually pushes, asserts what was printed, and then closes the server to
 * unblock the run.
 */
import { test } from "node:test";
import assert from "node:assert/strict";

import { parseTailArgs, runTail } from "./tail.js";
import { withCliHome, captureCli } from "../../test/support/cli_home.js";
import { startStubWss } from "../../test/support/stub_wss.js";

const SID = "s1";
const ev = (seq: number, text: string) => ({
  seq,
  sessionId: SID,
  ts: seq,
  kind: "agent.message",
  payload: { text },
});

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

test("parseTailArgs: id positional, -f/--since/--json", () => {
  const a = parseTailArgs([SID, "-f", "--since", "5", "--json"]);
  assert.equal(a.sessionId, SID);
  assert.equal(a.follow, true);
  assert.equal(a.since, 5);
  assert.equal(a.json, true);
});

test("without -f: --json prints the replay verbatim, one event per line, then exits 0", async () => {
  const events = [ev(1, "one"), ev(2, "two")];
  const stub = await startStubWss({ acceptBearer: "CACHED", events });
  try {
    const cap = await captureCli(() =>
      withCliHome(() => runTail([SID, "--json", "--port", String(stub.port)])),
    );
    assert.equal(cap.code, 0);
    assert.equal(cap.out, events.map((e) => JSON.stringify(e)).join("\n") + "\n");
  } finally {
    await stub.close();
  }
});

test("--since SEQ replays only events after that cursor", async () => {
  const events = [ev(1, "one"), ev(2, "two"), ev(3, "three")];
  const stub = await startStubWss({ acceptBearer: "CACHED", events });
  try {
    const cap = await captureCli(() =>
      withCliHome(() => runTail([SID, "--since", "2", "--json", "--port", String(stub.port)])),
    );
    assert.equal(cap.out, JSON.stringify(ev(3, "three")) + "\n");
  } finally {
    await stub.close();
  }
});

test("human output (no --json) goes through renderEvent, not a second renderer", async () => {
  const stub = await startStubWss({ acceptBearer: "CACHED", events: [ev(1, "hello there")] });
  try {
    const cap = await captureCli(() => withCliHome(() => runTail([SID, "--port", String(stub.port)])));
    assert.match(cap.out, /pi ›/); // the renderEvent bubble prefix
    assert.match(cap.out, /hello there/);
  } finally {
    await stub.close();
  }
});

test("-f replays the cursor then streams live events until the connection ends", async () => {
  const stub = await startStubWss({ acceptBearer: "CACHED", events: [ev(1, "replayed")] });
  let out = "";
  const origLog = console.log;
  console.log = (...a: unknown[]) => {
    out += a.join(" ") + "\n";
    return true;
  };
  try {
    // Do NOT await: `-f` resolves only when the socket closes.
    const done = withCliHome(() => runTail([SID, "-f", "--json", "--port", String(stub.port)]));
    await sleep(150); // let sub + replay + ack land
    stub.push(ev(2, "streamed"));
    await sleep(100);
    assert.match(out, /replayed/, "the cursor was replayed");
    assert.match(out, /streamed/, "a live event streamed in");
    await stub.close(); // ends the stream so `-f` returns
    await done;
  } finally {
    console.log = origLog;
  }
});

test("an err frame on sub (no such session) prints and exits non-zero", async () => {
  const stub = await startStubWss({ acceptBearer: "CACHED", subErr: "no such session" });
  try {
    const cap = await captureCli(() =>
      withCliHome(() => runTail(["nope", "--port", String(stub.port)])),
    );
    assert.notEqual(cap.code, 0);
    assert.match(cap.err, /no such session/);
  } finally {
    await stub.close();
  }
});
