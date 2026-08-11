/**
 * `makit handoff` — hand this session's work to a fresh one (SPEC-46 T19).
 *
 * The gesture the spec exists for: "this session is done / stuck / out of
 * context — write a handoff and continue, maybe on another harness." The
 * outgoing **agent** runs this itself, with no session or project arguments,
 * because its environment carries its identity (D3): `MAKIT_SESSION_ID` names
 * the parent and `MAKIT_CLI_TOKEN` authenticates as it.
 *
 * Three decisions shape what this does:
 *   - **D5** — the transcript is never replayed into the new agent. A codex
 *     thread cannot ingest a pi transcript, so the interchange format is a
 *     *message*: the rendered manifest, plus (with `--carry last:N`) a fenced
 *     excerpt fetched through the bounded `session.transcript` command.
 *   - **D15 inverse** — the child inherits the parent's worktree and branch,
 *     because the manifest's `file:line` references and the uncommitted work
 *     live there. `--worktree` opts into a fresh tree.
 *   - **D16** — the parent is left running. No close, no warning: two agents
 *     in one tree is a decision, and `makit ls` shows the sharing.
 *
 * `parentId` **is** sent — and is then checked, not trusted. An agent credential
 * has its parent derived from its own session and cannot name another (D9); a
 * human credential (this CLI) states the session it is handing off from, which the
 * server verifies exists and puts through the same depth/fan-out bound. Without
 * that the child would record a handoff *reason* with no parent: nothing for
 * `makit tree` to nest and nothing for the app to caption.
 */
import { readFileSync } from "node:fs";
import { connectCli, failCommand } from "./connect.js";
import { WireError } from "./client.js";
import { EXIT_USAGE } from "./exit-codes.js";
import { parseManifest, renderManifest, renderTranscriptExcerpt, type HandoffManifest } from "./handoff_manifest.js";
import type { SessionDTO, SessionEvent } from "../protocol.js";

export interface HandoffArgs {
  host: string;
  port: number;
  to?: string;
  goal?: string;
  next: string[];
  /** How many of the parent's last events to quote (`--carry last:N`). */
  carry?: number;
  /** A manifest file, or `-` for stdin. */
  file?: string;
  freshWorktree: boolean;
  branch?: string;
  base?: string;
  json: boolean;
}

export function parseHandoffArgs(argv: string[]): HandoffArgs {
  const a: HandoffArgs = { host: "127.0.0.1", port: 7777, next: [], freshWorktree: false, json: false };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i]!;
    if (t === "--host") a.host = String(argv[++i]);
    else if (t === "--port") a.port = Number(argv[++i]);
    else if (t === "--to") a.to = String(argv[++i]);
    else if (t === "--goal") a.goal = String(argv[++i]);
    else if (t === "--next") a.next.push(String(argv[++i]));
    else if (t === "--file") a.file = String(argv[++i]);
    else if (t === "-") a.file = "-";
    else if (t === "--worktree") a.freshWorktree = true;
    else if (t === "--branch") a.branch = String(argv[++i]);
    else if (t === "--base") a.base = String(argv[++i]);
    else if (t === "--json") a.json = true;
    else if (t === "--carry") {
      // `last:5` is the documented spelling; a bare count is accepted because an
      // agent writing the command from memory will try it.
      const raw = String(argv[++i] ?? "");
      const n = Number.parseInt(raw.replace(/^last:/, ""), 10);
      if (Number.isFinite(n) && n > 0) a.carry = n;
    }
  }
  return a;
}

function failUsage(message: string): never {
  console.error(`[makit] ${message}`);
  return process.exit(EXIT_USAGE);
}

/**
 * The manifest: a file, stdin, or the flags. Parsing is lenient by design (the
 * producer is an LLM) but a file that is not JSON at all is a usage error —
 * better to say so than to hand the child an empty brief.
 */
function resolveManifest(args: HandoffArgs): HandoffManifest {
  if (args.file !== undefined) {
    // The read is inside the guard too: only `JSON.parse` was covered, so a
    // mis-pathed or unreadable file threw a raw Node error with a stack. The
    // producer here is usually an agent, for which that reads as a crash rather
    // than "fix the path".
    let raw: string;
    try {
      raw = args.file === "-" ? readFileSync(0, "utf8") : readFileSync(args.file, "utf8");
    } catch (e) {
      return failUsage(`--file ${args.file} could not be read: ${(e as Error).message}`);
    }
    try {
      return parseManifest(JSON.parse(raw));
    } catch {
      return failUsage(`--file ${args.file} is not valid JSON`);
    }
  }
  const m: HandoffManifest = {};
  if (args.goal?.trim()) m.goal = args.goal.trim();
  if (args.next.length > 0) m.next = args.next;
  return m;
}

export async function runHandoff(argv: string[]): Promise<void> {
  const args = parseHandoffArgs(argv);
  const parentId = process.env.MAKIT_SESSION_ID;
  if (!parentId) {
    return failUsage(
      "handoff must run inside a makit session — MAKIT_SESSION_ID is not set (run it from an agent's shell)",
    );
  }
  // Resolved before connecting: a malformed manifest must not leave a
  // half-made session behind.
  const manifest = resolveManifest(args);
  // An empty manifest with nothing carried would send the child an empty first
  // message — a session spawned to continue work and told nothing about it. The
  // producer is usually an agent, which cannot ask what it was supposed to do.
  const empty =
    manifest.goal === undefined &&
    manifest.done === undefined &&
    manifest.next === undefined &&
    manifest.files === undefined &&
    manifest.gotchas === undefined &&
    manifest.openQuestions === undefined;
  if (empty && args.carry === undefined) {
    return failUsage("nothing to hand over — give at least --goal, --next, --file, or --carry");
  }

  const client = await connectCli(args);
  try {
    const parent = (await client.awaitSnapshot()).sessions.find((s: SessionDTO) => s.id === parentId);
    const projectId = parent?.projectId ?? process.env.MAKIT_PROJECT_ID;
    if (!projectId) {
      // Closed before exiting: `failUsage` calls `process.exit`, which terminates
      // synchronously and never runs the `finally` below — so the socket would go
      // away as a TCP reset rather than a close frame.
      client.close();
      return failUsage(`cannot resolve the project of session ${parentId} — is it still live?`);
    }

    // D15 inverse: inherit the parent's tree, or take a fresh one on request.
    let worktreePath = parent?.worktreePath ?? process.env.MAKIT_WORKTREE;
    let branch = parent?.branch;
    if (args.freshWorktree) {
      const created = await client.cmd("worktree.create", {
        projectId,
        branchName: args.branch ?? manifest.goal,
        baseBranch: args.base,
      });
      worktreePath = String(created.path);
      branch = typeof created.branch === "string" ? created.branch : undefined;
    }

    // D5: a bounded slice, server-side. Fetched before the spawn so a transcript
    // failure does not leave a childless session waiting for a first message.
    let excerpt = "";
    if (args.carry !== undefined) {
      const got = await client.cmd("session.transcript", { sessionId: parentId, limit: args.carry });
      excerpt = renderTranscriptExcerpt((got.events as SessionEvent[]) ?? []);
    }

    const spawned = await client.cmd("session.spawn", {
      projectId,
      agent: args.to,
      worktreePath,
      branch,
      // D10: where this session came from and why, so the app can caption it and
      // the spawn guard can attribute it. An agent token's `parentId` is derived
      // server-side from its own session; ours is stated and then verified.
      parentId,
      handoffReason: manifest.goal ?? `handoff from ${parentId.slice(0, 8)}`,
    });
    const sessionId = String(spawned.sessionId);

    const first = [renderManifest(manifest), excerpt].filter((s) => s.length > 0).join("\n");
    await client.cmd("send.message", { sessionId, text: first });

    if (args.json) {
      console.log(JSON.stringify({ sessionId }));
      return;
    }
    const to = args.to ? ` to ${args.to}` : "";
    const where = branch ? ` on ${branch}` : "";
    console.log(`[makit] handed off${to} — session ${sessionId}${where}`);
  } catch (e) {
    // Only a refusal from the server is reported as a sentence; a real bug keeps
    // its stack.
    if (e instanceof WireError) return failCommand(e);
    throw e;
  } finally {
    client.close();
  }
}
