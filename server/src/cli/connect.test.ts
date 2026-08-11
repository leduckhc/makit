/**
 * T8 (SPEC-46) — `cli/connect.ts`: the credential and liveness order (D2/C4).
 *
 * Every session verb reaches makit through here, so this is where the two exit
 * codes automation depends on are pinned: `3` when the daemon is down, `4` when
 * the credential is refused. The bearer under test is the CLI's *own* device
 * credential, never a paired phone's.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { connectCli } from "./connect.js";
import { cliCredentialPath } from "./client.js";
import { createControlServer, type ControlBackend } from "../daemon/control-server.js";
import { controlSocketPath } from "../daemon/paths.js";
import { startStubWss } from "../../test/support/stub_wss.js";
import { captureCli } from "../../test/support/cli_home.js";

function stubBackend(): ControlBackend {
  const unused = () => {
    throw new Error("not used by connect");
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

async function withHome(
  fn: () => Promise<void>,
  opts: { control?: boolean; bearer?: string } = {},
): Promise<void> {
  const prev = process.env.MAKIT_HOME;
  const home = mkdtempSync(join(tmpdir(), "makit-attach-home-"));
  process.env.MAKIT_HOME = home;
  const control = opts.control
    ? await createControlServer({ socketPath: controlSocketPath(), backend: stubBackend() })
    : undefined;
  if (opts.bearer) {
    mkdirSync(home, { recursive: true });
    writeFileSync(cliCredentialPath(), JSON.stringify({ deviceId: "cli-1", label: "cli@h", bearer: opts.bearer }));
  }
  try {
    await fn();
  } finally {
    await control?.close();
    if (prev === undefined) delete process.env.MAKIT_HOME;
    else process.env.MAKIT_HOME = prev;
    rmSync(home, { recursive: true, force: true });
  }
}

/** Capture stderr + the exit code of one `connectCli` call. */
async function capture(port: number): Promise<{ err: string; code: number; ok: boolean }> {
  let err = "";
  let code = 0;
  let ok = false;
  const origErr = console.error;
  const origExit = process.exit;
  console.error = (...a: unknown[]) => {
    err += a.join(" ") + "\n";
  };
  process.exit = ((c?: number) => {
    code = c ?? 0;
    throw new Error(`__exit__:${c}`);
  }) as typeof process.exit;
  try {
    const client = await connectCli({ host: "127.0.0.1", port });
    ok = true;
    client.close();
  } catch (e) {
    if (!/^__exit__:/.test((e as Error).message)) throw e;
  } finally {
    console.error = origErr;
    process.exit = origExit;
  }
  return { err, code, ok };
}

test("connectCli authenticates with the cli.json bearer, not a paired phone's", async () => {
  const stub = await startStubWss({ acceptBearer: "CLI-OWN", sessions: [] });
  try {
    await withHome(
      async () => {
        const res = await capture(stub.port);
        assert.equal(res.ok, true, res.err);
        assert.equal(res.code, 0);
      },
      { control: true, bearer: "CLI-OWN" },
    );
  } finally {
    await stub.close();
  }
});

test("a revoked CLI credential exits 4", async () => {
  const stub = await startStubWss({ acceptBearer: "CLI-OWN", sessions: [] });
  try {
    await withHome(
      async () => {
        const res = await capture(stub.port);
        assert.equal(res.code, 4);
        assert.match(res.err, /unknown device|unauthorized/i);
      },
      { control: true, bearer: "REVOKED" },
    );
  } finally {
    await stub.close();
  }
});

test("no daemon exits 3 with SPEC-02's message", async () => {
  await withHome(async () => {
    const res = await capture(1);
    assert.equal(res.code, 3);
    assert.match(res.err, /makit is not running/);
  });
});

// ---------------------------------------------------------------------------
// A flag with no value is a usage error, not a connection to nowhere
//
// Every verb parses `--host`/`--port` the same way — `String(argv[++i])` and
// `Number(argv[++i])` — so a trailing flag yields the literal host "undefined"
// or the port NaN. Both then travelled into `wss://<host>:<port>`, which fails
// as a *connection* error (exit 4, "your credential is the problem") for what is
// plainly a typo. Validated once here rather than at fifty-odd parse sites.
// ---------------------------------------------------------------------------

test("a NaN port (from `--port` with no value) is exit 2, before anything is dialled", async () => {
  const r = await captureCli(async () => {
    await connectCli({ host: "127.0.0.1", port: Number(undefined) });
  });
  assert.equal(r.code, 2, r.err);
  assert.match(r.err, /--port/);
});

test("a port outside 1..65535 is exit 2", async () => {
  for (const port of [0, -1, 70000, 1.5]) {
    const r = await captureCli(async () => {
      await connectCli({ host: "127.0.0.1", port });
    });
    assert.equal(r.code, 2, `port ${port}: ${r.err}`);
  }
});

test("an empty or literal-undefined host is exit 2", async () => {
  for (const host of ["", "undefined"]) {
    const r = await captureCli(async () => {
      await connectCli({ host, port: 7777 });
    });
    assert.equal(r.code, 2, `host ${JSON.stringify(host)}: ${r.err}`);
    assert.match(r.err, /--host/);
  }
});
