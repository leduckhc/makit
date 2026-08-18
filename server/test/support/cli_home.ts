/**
 * Shared harness for the SPEC-cli-as-client session-verb CLI tests (`send`, `tail`,
 * `resume`, `rm`, …).
 *
 * Every one of these verbs is a client of `cli/client.ts`, so every one of
 * their tests needs the same scaffolding: an isolated `MAKIT_HOME`, a control
 * socket that answers `cli.grant`, a cached `cli.json` bearer, and a capture of
 * stdout/stderr/exit. `ls`/`new` predate this and inline it; the T14 verbs share
 * it here rather than copying it four more times.
 *
 * The scaffolding owns the **whole** credential surface, not just the home dir.
 * See `hideAmbientCliToken` for the half that was missing.
 */
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { cliCredentialPath } from "../../src/cli/client.js";
import { stdout } from "../../src/cli/out.js";
import { createControlServer, type ControlBackend } from "../../src/daemon/control-server.js";
import { controlSocketPath } from "../../src/daemon/paths.js";

/**
 * Hide an ambient `MAKIT_CLI_TOKEN` for the length of one test, and return the
 * undo.
 *
 * A cached `cli.json` bearer is only the fixture's bearer while nothing outranks
 * it. `resolveBearer` reads `MAKIT_CLI_TOKEN` first (D2/D3 order), so a token in
 * the environment silently replaces the one the test wrote, and the stub server
 * then answers `unknown device`.
 *
 * A makit session exports that token to every agent it spawns. So an agent that
 * runs this suite from inside makit hits it, while CI and a plain shell stay
 * green. Isolating `MAKIT_HOME` alone is therefore not isolation.
 *
 * Call this in any harness that writes a `cli.json`, not only in `withCliHome`:
 * five CLI test files still inline that ritual.
 */
export function hideAmbientCliToken(): () => void {
  const prev = process.env.MAKIT_CLI_TOKEN;
  delete process.env.MAKIT_CLI_TOKEN;
  return () => {
    if (prev === undefined) delete process.env.MAKIT_CLI_TOKEN;
    else process.env.MAKIT_CLI_TOKEN = prev;
  };
}

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
 *
 * An ambient `MAKIT_CLI_TOKEN` is hidden for the duration, so the cached bearer
 * is the one the CLI actually sends (`hideAmbientCliToken`).
 */
export async function withCliHome(
  fn: () => Promise<void>,
  opts: { control?: boolean; bearer?: string } = {},
): Promise<void> {
  const bearer = opts.bearer ?? "CACHED";
  const control = opts.control ?? true;
  const prev = process.env.MAKIT_HOME;
  const restoreToken = hideAmbientCliToken();
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
    restoreToken();
    rmSync(home, { recursive: true, force: true });
  }
}

export interface Captured {
  out: string;
  err: string;
  code: number;
}

/**
 * Capture stdout (`console.log` plus the `cli/out.ts` seam that `renderEvent`
 * output goes through), stderr, and the exit code of one CLI run. `process.exit`
 * is turned into a throw so the run unwinds instead of killing the test process.
 *
 * It deliberately does **not** touch `process.stdout.write`: `node --test`
 * writes its own result stream there, and swallowing it drops whole tests from
 * the report — the file then fails with no diagnostic at all.
 */
export async function captureCli(run: () => Promise<void>): Promise<Captured> {
  let out = "";
  let err = "";
  let code = 0;
  const origLog = console.log;
  const origErr = console.error;
  const origWrite = stdout.write;
  const origExit = process.exit;
  console.log = (...a: unknown[]) => {
    out += a.join(" ") + "\n";
    return true;
  };
  console.error = (...a: unknown[]) => {
    err += a.join(" ") + "\n";
    return true;
  };
  stdout.write = (chunk: string) => {
    out += chunk;
  };
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
    stdout.write = origWrite;
    process.exit = origExit;
  }
  return { out, err, code };
}
