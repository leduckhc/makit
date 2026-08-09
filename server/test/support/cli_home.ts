/**
 * Shared harness for the SPEC-46 session-verb CLI tests (`send`, `tail`,
 * `resume`, `rm`, …).
 *
 * Every one of these verbs is a client of `cli/client.ts`, so every one of
 * their tests needs the same scaffolding: an isolated `MAKIT_HOME`, a control
 * socket that answers `cli.grant`, a cached `cli.json` bearer, and a capture of
 * stdout/stderr/exit. `ls`/`new` predate this and inline it; the T14 verbs share
 * it here rather than copying it four more times.
 */
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { cliCredentialPath } from "../../src/cli/client.js";
import { createControlServer, type ControlBackend } from "../../src/daemon/control-server.js";
import { controlSocketPath } from "../../src/daemon/paths.js";

/** A control backend that only has to answer `cli.grant` for these tests. */
function stubBackend(bearer: string): ControlBackend {
  const unused = () => {
    throw new Error("control verb not used by this CLI test");
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
    cliGrant: () => ({ deviceId: "cli-1", label: "cli@h", bearer, created: true }),
  } as unknown as ControlBackend;
}

/**
 * Run `fn` with an isolated `MAKIT_HOME`. By default a control socket is up and
 * a `cli.json` bearer is cached; pass `control: false` to test "daemon down".
 */
export async function withCliHome(
  fn: () => Promise<void>,
  opts: { control?: boolean; bearer?: string } = {},
): Promise<void> {
  const bearer = opts.bearer ?? "CACHED";
  const control = opts.control ?? true;
  const prev = process.env.MAKIT_HOME;
  const home = mkdtempSync(join(tmpdir(), "makit-cli-home-"));
  process.env.MAKIT_HOME = home;
  const server = control
    ? await createControlServer({ socketPath: controlSocketPath(), backend: stubBackend(bearer) })
    : undefined;
  mkdirSync(home, { recursive: true });
  writeFileSync(cliCredentialPath(), JSON.stringify({ deviceId: "cli-1", label: "cli@h", bearer }));
  try {
    await fn();
  } finally {
    await server?.close();
    if (prev === undefined) delete process.env.MAKIT_HOME;
    else process.env.MAKIT_HOME = prev;
    rmSync(home, { recursive: true, force: true });
  }
}

export interface Captured {
  out: string;
  err: string;
  code: number;
}

/**
 * Capture stdout (both `console.log` and raw `process.stdout.write`, which
 * `renderEvent` uses), stderr, and the exit code of one CLI run. `process.exit`
 * is turned into a throw so the run unwinds instead of killing the test process.
 */
export async function captureCli(run: () => Promise<void>): Promise<Captured> {
  let out = "";
  let err = "";
  let code = 0;
  const origLog = console.log;
  const origErr = console.error;
  const origWrite = process.stdout.write;
  const origExit = process.exit;
  console.log = (...a: unknown[]) => {
    out += a.join(" ") + "\n";
    return true;
  };
  console.error = (...a: unknown[]) => {
    err += a.join(" ") + "\n";
    return true;
  };
  process.stdout.write = ((chunk: unknown) => {
    out += typeof chunk === "string" ? chunk : String(chunk);
    return true;
  }) as typeof process.stdout.write;
  process.exit = ((c?: number) => {
    code = c ?? 0;
    throw new Error(`__exit__:${c}`);
  }) as typeof process.exit;
  try {
    await run();
  } catch (e) {
    if (!/^__exit__:/.test((e as Error).message)) throw e;
  } finally {
    console.log = origLog;
    console.error = origErr;
    process.stdout.write = origWrite;
    process.exit = origExit;
  }
  return { out, err, code };
}
