/**
 * T14 (SPEC-46) — `makit resume`: bring a cold, resumable session back to a
 * live agent (`session.attach`).
 */
import { test } from "node:test";
import assert from "node:assert/strict";

import { parseResumeArgs, runResume } from "./resume.js";
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
      return opts.err ? { __err: opts.err } : { sessionId: m.sessionId };
    },
  });
  try {
    const cap = await captureCli(() => withCliHome(() => runResume([...argv, "--port", String(stub.port)])));
    return { ...cap, cmds };
  } finally {
    await stub.close();
  }
}

const sent = (cmds: Record<string, unknown>[], kind: string) => cmds.find((c) => c.kind === kind);

test("parseResumeArgs: reads the positional id and host/port", () => {
  const a = parseResumeArgs(["s1", "--host", "1.2.3.4", "--port", "9"]);
  assert.equal(a.sessionId, "s1");
  assert.equal(a.host, "1.2.3.4");
  assert.equal(a.port, 9);
});

test("resume re-attaches the session via session.attach", async () => {
  const r = await run(["s1"]);
  assert.equal(r.code, 0, r.err);
  assert.equal(sent(r.cmds, "session.attach")!.sessionId, "s1");
});

test("a missing id is a usage error (exit 2), nothing sent", async () => {
  const r = await run([]);
  assert.equal(r.code, 2);
  assert.equal(r.cmds.length, 0);
});

test("an err frame prints and exits non-zero", async () => {
  const r = await run(["nope"], { err: "session is not resumable" });
  assert.notEqual(r.code, 0);
  assert.match(r.err, /not resumable/);
});
