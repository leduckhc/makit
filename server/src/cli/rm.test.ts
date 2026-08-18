/**
 * T14 (SPEC-cli-as-client) — `makit rm`: end a session from the terminal.
 *
 * The one decision here is the default: `rm` **closes** (a soft, recoverable
 * hide — the session stays resumable and `--closed` still lists it), and only
 * `--kill` tears the agent down for good. Defaulting to the destructive verb
 * would be the wrong way round, so the test pins it.
 */
import { test } from "node:test";
import assert from "node:assert/strict";

import { parseRmArgs, runRm } from "./rm.js";
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
    const cap = await captureCli(() => withCliHome(() => runRm([...argv, "--port", String(stub.port)])));
    return { ...cap, cmds };
  } finally {
    await stub.close();
  }
}

const sent = (cmds: Record<string, unknown>[], kind: string) => cmds.find((c) => c.kind === kind);

test("parseRmArgs: defaults to close (kill is opt-in), reads the positional id", () => {
  const a = parseRmArgs(["s1"]);
  assert.equal(a.sessionId, "s1");
  assert.equal(a.kill, false);
  assert.equal(a.host, "127.0.0.1");
  assert.equal(a.port, 7777);
});

test("parseRmArgs: --kill flips to the destructive verb", () => {
  const a = parseRmArgs(["s1", "--kill", "--port", "9"]);
  assert.equal(a.kill, true);
  assert.equal(a.port, 9);
});

test("by default rm closes (recoverable), never kills", async () => {
  const r = await run(["s1"]);
  assert.equal(r.code, 0, r.err);
  assert.equal(sent(r.cmds, "session.close")!.sessionId, "s1");
  assert.equal(sent(r.cmds, "session.kill"), undefined);
});

test("--kill kills and does not close", async () => {
  const r = await run(["s1", "--kill"]);
  assert.equal(r.code, 0, r.err);
  assert.equal(sent(r.cmds, "session.kill")!.sessionId, "s1");
  assert.equal(sent(r.cmds, "session.close"), undefined);
});

test("a missing id is a usage error (exit 2), nothing sent", async () => {
  const r = await run([]);
  assert.equal(r.code, 2);
  assert.equal(r.cmds.length, 0);
});

test("an err frame (no_such_session) prints and exits non-zero", async () => {
  const r = await run(["nope"], { err: "no such session" });
  assert.notEqual(r.code, 0);
  assert.match(r.err, /no such session/);
});
