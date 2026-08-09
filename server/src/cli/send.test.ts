/**
 * T14 (SPEC-46) — `makit send`: post a message to a session (`send.message`).
 *
 * `--attach` (SPEC-33) is deliberately NOT wired in T14: the byte upload to the
 * server's `POST /media` endpoint needs the CLI's bearer exposed, an HTTPS
 * client that tolerates the self-signed loopback cert, and a mime map — more
 * than the small amount of code the task budgeted for it. Rather than swallow an
 * attachment silently (which would send a text-only turn about an image the
 * agent never sees), the flag is parsed and refused with a usage error. The rest
 * of `send` ships.
 */
import { test } from "node:test";
import assert from "node:assert/strict";

import { parseSendArgs, runSend } from "./send.js";
import { withCliHome, captureCli } from "../../test/support/cli_home.js";
import { startStubWss } from "../../test/support/stub_wss.js";

interface Run {
  out: string;
  err: string;
  code: number;
  cmds: Record<string, unknown>[];
}

async function run(argv: string[], opts: { err?: string } = {}): Promise<Run> {
  const cmds: Record<string, unknown>[] = [];
  const stub = await startStubWss({
    acceptBearer: "CACHED",
    onCmd: (m) => {
      cmds.push(m);
      return opts.err ? { __err: opts.err } : {};
    },
  });
  try {
    const cap = await captureCli(() => withCliHome(() => runSend([...argv, "--port", String(stub.port)])));
    return { ...cap, cmds };
  } finally {
    await stub.close();
  }
}

const sent = (cmds: Record<string, unknown>[], kind: string) => cmds.find((c) => c.kind === kind);

test("parseSendArgs: id positional, -m message, --attach collects files", () => {
  const a = parseSendArgs(["s1", "-m", "hello", "--attach", "a.png", "--attach", "b.png"]);
  assert.equal(a.sessionId, "s1");
  assert.equal(a.message, "hello");
  assert.deepEqual(a.attach, ["a.png", "b.png"]);
});

test("send posts send.message with the session id and text", async () => {
  const r = await run(["s1", "-m", "fix the migration"]);
  assert.equal(r.code, 0, r.err);
  const msg = sent(r.cmds, "send.message")!;
  assert.equal(msg.sessionId, "s1");
  assert.equal(msg.text, "fix the migration");
});

test("a missing id or message is a usage error (exit 2), nothing sent", async () => {
  assert.equal((await run(["-m", "hi"])).code, 2);
  assert.equal((await run(["s1"])).code, 2);
  const r = await run(["s1"]);
  assert.equal(r.cmds.length, 0);
});

test("--attach is refused with a usage error rather than silently dropped", async () => {
  const r = await run(["s1", "-m", "look", "--attach", "shot.png"]);
  assert.equal(r.code, 2);
  assert.match(r.err, /attach/i);
  assert.equal(r.cmds.length, 0, "no turn is sent when an attachment cannot be honoured");
});

test("an err frame (no_such_session) prints and exits non-zero", async () => {
  const r = await run(["nope", "-m", "hi"], { err: "no such session" });
  assert.notEqual(r.code, 0);
  assert.match(r.err, /no such session/);
});
