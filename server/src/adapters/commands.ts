/**
 * Shared slash-palette command fetcher for adapters that don't spawn their own
 * pi process natively. MirrorAdapter (file-tailing) and IngestAdapter (push
 * from pino-mirror extension) both need this — their underlying pi has no RPC
 * stdin we can query directly, so we spawn a short-lived side-child
 * (`pi --mode rpc --no-session`) at startup to call `get_commands` once.
 *
 * Skills/prompts/extensions are filesystem-driven, so a second pi process in
 * the same cwd returns the same list. The child's lifetime is bounded (5s
 * timeout; killed on adapter kill). The fetch is best-effort: if it fails or
 * times out, the slash palette stays empty but the adapter continues unchanged.
 */
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import type { AdapterEvent } from "./adapter.js";

/**
 * Fetcher for the slash command palette: resolves the available agent commands
 * (skills/prompts/extensions) for the given cwd. Throw to signal fetch failure;
 * the caller treats throws as "no commands available".
 */
export type CommandsFetcher = (cwd: string) => Promise<unknown[]>;

/** Handle for a live commands fetch: promise + child process for kill-time cleanup. */
export interface CommandsFetchHandle {
  promise: Promise<unknown[]>;
  child: ChildProcessWithoutNullStreams;
}

/**
 * Default production fetcher: spawns `pi --mode rpc --no-session` and calls
 * `get_commands`. Returns both the promise and the child so adapters can
 * SIGKILL it from their `kill()` method. ~1.2s wall time. Uses `PINO_PI_BIN`
 * to override `pi`.
 */
export function fetchPiCommands(cwd: string): CommandsFetchHandle {
  const piBin = process.env.PINO_PI_BIN || "pi";
  const child = spawn(piBin, ["--mode", "rpc", "--no-session"], { cwd });
  const promise = new Promise<unknown[]>((resolve, reject) => {
    let stdout = "";
    let settled = false;
    const finish = (ok: boolean, value: unknown[] | Error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { child.kill("SIGTERM"); } catch { /* already dead */ }
      ok ? resolve(value as unknown[]) : reject(value);
    };
    const timer = setTimeout(() => finish(false, new Error("commands fetch timed out")), 5000);

    child.stdout.on("data", (c: Buffer) => {
      stdout += c.toString();
      for (const line of stdout.split("\n")) {
        if (!line.trim()) continue;
        let o: unknown;
        try { o = JSON.parse(line); } catch { continue; }
        const ev = o as { type?: string; command?: string; success?: boolean; data?: { commands?: unknown[] } };
        if (ev.type === "response" && ev.command === "get_commands") {
          if (ev.success && Array.isArray(ev.data?.commands)) {
            finish(true, ev.data!.commands);
          } else {
            finish(false, new Error("get_commands failed"));
          }
          return;
        }
      }
    });

    child.stderr?.on("data", () => { /* swallow pi diagnostics */ });
    child.on("error", (err: Error) => finish(false, err));
    child.on("exit", () => finish(false, new Error("commands child exited before response")));

    try {
      child.stdin.write(JSON.stringify({ id: "commands-fetch", type: "get_commands" }) + "\n");
    } catch (err) {
      finish(false, err as Error);
    }
  });

  return { promise, child };
}

/**
 * Build a session.commands AdapterEvent from a commands list, or null if empty/invalid.
 */
export function buildCommandsEvent(commands: unknown[]): AdapterEvent | null {
  if (!Array.isArray(commands) || commands.length === 0) return null;
  return {
    ts: Date.now(),
    kind: "session.commands",
    payload: { commands },
  };
}
