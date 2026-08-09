/**
 * T8 (SPEC-46) — `attach` re-homed on the CLI's own credential.
 *
 * The defect being deleted (spec §2): `readBearer()` read
 * `~/.makit/devices.json` and took `arr[0].bearer` — the *phone's* credential.
 * So revoking the phone killed the CLI, revoking the CLI was impossible, and
 * capability checks had no subject. The grep test below is the regression lock:
 * no CLI code path may read that file again.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, readdirSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { connectAttach } from "./attach.js";
import { cliCredentialPath } from "./client.js";
import { createControlServer, type ControlBackend } from "../daemon/control-server.js";
import { controlSocketPath } from "../daemon/paths.js";
import { startStubWss } from "../../test/support/stub_wss.js";

test("no file under src/cli reads devices.json (the §2 defect stays deleted)", () => {
  const dir = new URL(".", import.meta.url).pathname;
  // Comments are stripped first: the *prose* explaining the deleted hack must
  // stay readable, it is only a code path reading the file that is forbidden.
  const code = (src: string) => src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
  const offenders = readdirSync(dir)
    .filter((f) => f.endsWith(".ts") && !f.endsWith(".test.ts"))
    .filter((f) => code(readFileSync(join(dir, f), "utf8")).includes("devices.json"));
  assert.deepEqual(offenders, [], `these read the phone's credential: ${offenders.join(", ")}`);
});

function stubBackend(): ControlBackend {
  const unused = () => {
    throw new Error("not used by attach");
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

/** Capture stderr + the exit code of one `connectAttach` call. */
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
    const client = await connectAttach({ host: "127.0.0.1", port });
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

test("attach authenticates with the cli.json bearer, not a paired phone's", async () => {
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

test("attach with no daemon exits 3 with SPEC-02's message", async () => {
  await withHome(async () => {
    const res = await capture(1);
    assert.equal(res.code, 3);
    assert.match(res.err, /makit is not running/);
  });
});
