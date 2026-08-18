/**
 * `makit tree` — who spawned whom, and why (SPEC-cli-as-client U1, D10).
 *
 * A pure projection of `sessions.snapshot`: lineage is protocol data, so this
 * needs no command of its own. Rendering is kept free of I/O like `render.ts`,
 * so the hostile shapes below are unit-testable without a server.
 *
 * Two rules come from lineage being *persisted* data rather than a live graph:
 * an **orphan** (a `parentId` whose session is closed, killed, or simply not in
 * this snapshot) renders at the root naming the parent it lost, and a **cycle**
 * terminates. A session that silently vanished from this view, or a renderer that
 * recursed forever on a forged loop, would both be worse than a flat list.
 */
import { withClient } from "./connect.js";
import { stdout } from "./out.js";
import type { SessionDTO } from "../protocol.js";
import { parseFlags, str, int, bool } from "./flags.js";

export interface TreeArgs {
  host: string;
  port: number;
  json: boolean;
  projectId?: string;
}

export function parseTreeArgs(argv: string[]): TreeArgs {
  const p = parseFlags(argv, {
    host: { type: "string", def: "127.0.0.1" },
    port: { type: "int", def: 7777 },
    json: { type: "bool" },
    project: { type: "string" },
  });
  return {
    host: str(p, "host")!,
    port: int(p, "port")!,
    json: bool(p, "json"),
    projectId: str(p, "project"),
  };
}

/** One line: the session, plus why it exists when that is not "a human asked". */
function line(session: SessionDTO, depth: number, lostParent?: string): string {
  const why: string[] = [];
  if (session.handoffReason) why.push(`handed off: ${session.handoffReason}`);
  // `app` is the overwhelming default; saying so on every row is noise.
  if (session.origin && session.origin !== "app") why.push(`via ${session.origin}`);
  if (lostParent) why.push(`parent ${lostParent} is gone`);
  const suffix = why.length > 0 ? `  (${why.join(", ")})` : "";
  return `${"  ".repeat(depth)}${session.id}  [${session.status}]  ${session.title || "(untitled)"}${suffix}`;
}

/**
 * Render the spawn forest. Every session in `sessions` appears exactly once,
 * whatever the shape of the lineage — that invariant is what makes the cycle and
 * orphan handling provable rather than hopeful.
 */
export function renderTree(sessions: readonly SessionDTO[]): string {
  const byId = new Map(sessions.map((x) => [x.id, x]));
  const children = new Map<string, SessionDTO[]>();
  const roots: { session: SessionDTO; lostParent?: string }[] = [];

  for (const session of sessions) {
    const parentId = session.parentId;
    // A parent that is not here (closed/killed/uncached) makes this a root
    // that still says which parent it lost. Self-parenthood is a root too.
    if (!parentId || parentId === session.id || !byId.has(parentId)) {
      roots.push({ session, lostParent: parentId && parentId !== session.id ? parentId : undefined });
      continue;
    }
    const siblings = children.get(parentId);
    if (siblings) siblings.push(session);
    else children.set(parentId, [session]);
  }

  const out: string[] = [];
  // `seen` is the cycle guard AND the appears-once guarantee: a forged loop whose
  // members are all reachable from each other has no root, so any member left
  // unprinted is emitted flat afterwards rather than lost.
  const seen = new Set<string>();
  const walk = (session: SessionDTO, depth: number, lostParent?: string): void => {
    if (seen.has(session.id)) return;
    seen.add(session.id);
    out.push(line(session, depth, lostParent));
    for (const child of children.get(session.id) ?? []) walk(child, depth + 1);
  };

  for (const root of roots) walk(root.session, 0, root.lostParent);
  for (const session of sessions) if (!seen.has(session.id)) walk(session, 0);

  return out.join("\n") + (out.length > 0 ? "\n" : "");
}

export async function runTree(argv: string[]): Promise<void> {
  const args = parseTreeArgs(argv);
  await withClient(args, async (client) => {
    const all = (await client.awaitSnapshot()).sessions;
    const sessions = args.projectId ? all.filter((x) => x.projectId === args.projectId) : all;
    if (args.json) {
      // D7: the wire, unmodified — the tree is a *rendering*, not a new schema.
      console.log(JSON.stringify(sessions));
      return;
    }
    if (sessions.length === 0) {
      console.log("no sessions");
      return;
    }
    stdout.write(renderTree(sessions));
  });
}
