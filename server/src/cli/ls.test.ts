/**
 * T7 (SPEC-46) — `makit ls`: the output contract (D7) and the exit codes (D8/C4).
 *
 * `ls` is the first verb that is a client of the WSS transport, so these tests
 * pin the two contracts every later verb inherits: `--json` is the wire
 * unmodified (nothing else on stdout), and a dead daemon is exit `3` while a
 * refused credential is exit `4` — a distinction automation depends on.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { parseLsArgs, runLs } from "./ls.js";
import { cliCredentialPath } from "./client.js";
import { createControlServer, type ControlBackend } from "../daemon/control-server.js";
import { controlSocketPath } from "../daemon/paths.js";
import { startStubWss } from "../../test/support/stub_wss.js";

const SESSIONS = [
  {
    id: "s1",
    projectId: "p1",
    agent: "pi",
    title: "make the migration idempotent",
    status: "idle",
    lastActivityAt: 1,
  },
  { id: "s2", projectId: "p2", agent: "codex", title: "second", status: "running", lastActivityAt: 2 },
];

/** Run `fn` with an isolated MAKIT_HOME (no control socket unless asked for one). */
async function withHome(
  fn: (home: string) => Promise<void>,
  opts: { control?: boolean; bearer?: string } = {},
): Promise<void> {
  const prev = process.env.MAKIT_HOME;
  const home = mkdtempSync(join(tmpdir(), "makit-ls-home-"));
  process.env.MAKIT_HOME = home;
  const control = opts.control
    ? await createControlServer({ socketPath: controlSocketPath(), backend: stubBackend() })
    : undefined;
  if (opts.bearer) {
    mkdirSync(home, { recursive: true });
    writeFileSync(cliCredentialPath(), JSON.stringify({ deviceId: "cli-1", label: "cli@h", bearer: opts.bearer }));
  }
  try {
    await fn(home);
  } finally {
    await control?.close();
    if (prev === undefined) delete process.env.MAKIT_HOME;
    else process.env.MAKIT_HOME = prev;
    rmSync(home, { recursive: true, force: true });
  }
}

/** A control backend that only has to answer `cli.grant` for these tests. */
function stubBackend(): ControlBackend {
  const unused = () => {
    throw new Error("not used by ls");
  };
  return {
    status: unused,
    pairMint: unused,
    pairCurrent: unused,
    devicesList: unused,
    devicesRevoke: unused,
    sessionsList: unused,
    serverStop: unused,
    logsTail: unused,
    cliGrant: () => ({ deviceId: "cli-1", label: "cli@h", bearer: "GRANTED", created: true }),
  } as unknown as ControlBackend;
}

/** Capture stdout/stderr and the exit code of one `runLs` call. */
async function capture(argv: string[]): Promise<{ out: string; err: string; code: number }> {
  let out = "";
  let err = "";
  let code = 0;
  const origLog = console.log;
  const origErr = console.error;
  const origExit = process.exit;
  console.log = (...a: unknown[]) => {
    out += a.join(" ") + "\n";
  };
  console.error = (...a: unknown[]) => {
    err += a.join(" ") + "\n";
  };
  process.exit = ((c?: number) => {
    code = c ?? 0;
    throw new Error(`__exit__:${c}`);
  }) as typeof process.exit;
  try {
    await runLs(argv);
  } catch (e) {
    if (!/^__exit__:/.test((e as Error).message)) throw e;
  } finally {
    console.log = origLog;
    console.error = origErr;
    process.exit = origExit;
  }
  return { out, err, code };
}

// ---------------------------------------------------------------------------
// argv parsing
// ---------------------------------------------------------------------------

test("parseLsArgs: defaults to loopback:7777, human output, active sessions", () => {
  const a = parseLsArgs([]);
  assert.equal(a.host, "127.0.0.1");
  assert.equal(a.port, 7777);
  assert.equal(a.json, false);
  assert.equal(a.archived, false);
  assert.equal(a.projectId, undefined);
});

test("parseLsArgs: --json --archived --project P --host H --port N", () => {
  const a = parseLsArgs(["--json", "--archived", "--project", "p1", "--host", "1.2.3.4", "--port", "9"]);
  assert.deepEqual(
    { host: a.host, port: a.port, json: a.json, archived: a.archived, projectId: a.projectId },
    { host: "1.2.3.4", port: 9, json: true, archived: true, projectId: "p1" },
  );
});

// ---------------------------------------------------------------------------
// D7 — the output contract
// ---------------------------------------------------------------------------

test("--json emits exactly the sessions array from the snapshot frame, and nothing else", async () => {
  const stub = await startStubWss({ acceptBearer: "CACHED", sessions: SESSIONS });
  try {
    await withHome(
      async () => {
        const { out, code } = await capture(["--json", "--port", String(stub.port)]);
        assert.equal(code, 0);
        assert.equal(out, JSON.stringify(SESSIONS) + "\n");
      },
      { control: true, bearer: "CACHED" },
    );
  } finally {
    await stub.close();
  }
});

test("--json --project filters to that project, still as the wire's own objects", async () => {
  const stub = await startStubWss({ acceptBearer: "CACHED", sessions: SESSIONS });
  try {
    await withHome(
      async () => {
        const { out } = await capture(["--json", "--project", "p2", "--port", String(stub.port)]);
        assert.equal(out, JSON.stringify([SESSIONS[1]]) + "\n");
      },
      { control: true, bearer: "CACHED" },
    );
  } finally {
    await stub.close();
  }
});

test("human output prints one line per session, and 'no sessions' when empty", async () => {
  const stub = await startStubWss({ acceptBearer: "CACHED", sessions: SESSIONS });
  try {
    await withHome(
      async () => {
        const { out, code } = await capture(["--port", String(stub.port)]);
        assert.equal(code, 0);
        const lines = out.trimEnd().split("\n");
        assert.equal(lines.length, 2);
        assert.match(lines[0]!, /s1/);
        assert.match(lines[0]!, /make the migration idempotent/);
      },
      { control: true, bearer: "CACHED" },
    );
  } finally {
    await stub.close();
  }

  const empty = await startStubWss({ acceptBearer: "CACHED", sessions: [] });
  try {
    await withHome(
      async () => {
        const { out } = await capture(["--port", String(empty.port)]);
        assert.equal(out, "no sessions\n");
      },
      { control: true, bearer: "CACHED" },
    );
  } finally {
    await empty.close();
  }
});

test("--archived reads session.listArchived instead of the pushed snapshot", async () => {
  const archived = [{ id: "a1", projectId: "p1", agent: "pi", title: "old", status: "idle", lastActivityAt: 3 }];
  let asked = "";
  const stub = await startStubWss({
    acceptBearer: "CACHED",
    sessions: SESSIONS,
    onCmd: (m) => {
      asked = String(m.kind);
      return { sessions: archived };
    },
  });
  try {
    await withHome(
      async () => {
        const { out } = await capture(["--json", "--archived", "--port", String(stub.port)]);
        assert.equal(asked, "session.listArchived");
        assert.equal(out, JSON.stringify(archived) + "\n");
      },
      { control: true, bearer: "CACHED" },
    );
  } finally {
    await stub.close();
  }
});

// ---------------------------------------------------------------------------
// D8/C4 — exit 3 (daemon down) vs exit 4 (credential refused)
// ---------------------------------------------------------------------------

test("daemon down → SPEC-02's message and exit 3, with no stack trace", async () => {
  await withHome(async () => {
    const { err, code, out } = await capture(["--port", "1"]);
    assert.equal(code, 3);
    assert.match(err, /makit is not running/);
    assert.doesNotMatch(err, /at .*\(/); // no stack trace
    assert.equal(out, "");
  });
});

test("a refused credential → exit 4 (not 3, not a crash)", async () => {
  const stub = await startStubWss({ acceptBearer: "GOOD", sessions: SESSIONS });
  try {
    await withHome(
      async () => {
        const { err, code, out } = await capture(["--port", String(stub.port)]);
        assert.equal(code, 4);
        assert.match(err, /unknown device|unauthorized|not authorized/i);
        assert.equal(out, "");
      },
      { control: true, bearer: "REVOKED" },
    );
  } finally {
    await stub.close();
  }
});

test("no server listening on the WSS port → exit 4", async () => {
  await withHome(
    async () => {
      const { code } = await capture(["--port", "1"]);
      assert.equal(code, 4);
    },
    { control: true, bearer: "CACHED" },
  );
});

test("a refused session.listArchived is a sentence and exit 1, not an unhandled rejection", async () => {
  // `ls` catches AuthError only, so a plain server refusal on this path escaped
  // as a rejected promise: a node stack trace instead of the one-line refusal
  // every other verb prints, and an exit code nothing chose.
  const stub = await startStubWss({
    acceptBearer: "CACHED",
    sessions: SESSIONS,
    onCmd: () => ({ __err: "archived sessions are unavailable while the store is compacting" }),
  });
  try {
    await withHome(
      async () => {
        const { err, code, out } = await capture(["--archived", "--port", String(stub.port)]);
        assert.equal(code, 1);
        assert.match(err, /while the store is compacting/);
        assert.doesNotMatch(err, /at .*\.ts:|node:internal/, "no stack trace");
        assert.equal(out, "");
      },
      { control: true, bearer: "CACHED" },
    );
  } finally {
    await stub.close();
  }
});
