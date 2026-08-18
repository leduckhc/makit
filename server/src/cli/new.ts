/**
 * `makit new` — start a session from the terminal (SPEC-cli-as-client T12).
 *
 * Composes three commands that already exist (D4): `worktree.create`, then
 * `session.spawn`, then — when a message was given — `send.message`, which is
 * what promotes the draft (names it, applies the pre-spawn config picks). There
 * is deliberately no `initialPrompt` on the wire: a second launch path through
 * the same promotion logic would buy nothing.
 *
 * A session owns a worktree, always (D15). With `-m` the message seeds the
 * branch name, so `makit new -m "fix the migration"` lands on
 * `fix-the-migration` instead of `worktree-<uuid>` — the CLI passes the raw text
 * and the server slugifies it (`slugifyBranch`) and de-duplicates it
 * (`uniqueBranch`), so this file must not pre-slugify. `--here` is the explicit
 * opt-out for "run in the tree I'm standing in".
 */
import { withClient } from "./connect.js";
import { parseFlags, str, int, bool, list, type Spec, type Parsed , failUsage } from "./flags.js";
import type { MakitClient } from "./client.js";
import type { ProjectDTO } from "../protocol.js";

export interface ConfigPick {
  id: string;
  value: string;
}

export interface NewArgs {
  host: string;
  port: number;
  message?: string;
  agent?: string;
  projectId?: string;
  branch?: string;
  base?: string;
  here: boolean;
  json: boolean;
  configOptions: ConfigPick[];
}

export const NEW_FLAGS: Spec = {
  host: { type: "string", def: "127.0.0.1" },
  port: { type: "int", def: 7777 },
  message: { type: "string", alias: "-m" },
  agent: { type: "string" },
  project: { type: "string" },
  branch: { type: "string" },
  base: { type: "string" },
  here: { type: "bool" },
  json: { type: "bool" },
  config: { type: "list" },
};

export function parseNewArgs(argv: string[]): NewArgs {
  return newArgsFrom(parseFlags(argv, NEW_FLAGS));
}

/** Shared with `run`, which parses one argv against this spec and `wait`'s. */
export function newArgsFrom(p: Parsed): NewArgs {
  return {
    host: str(p, "host")!,
    port: int(p, "port")!,
    message: str(p, "message"),
    agent: str(p, "agent"),
    projectId: str(p, "project"),
    branch: str(p, "branch"),
    base: str(p, "base"),
    here: bool(p, "here"),
    json: bool(p, "json"),
    // `--config id=value`; a pick with no `=` is dropped, as before.
    configOptions: list(p, "config").flatMap((raw) => {
      const eq = raw.indexOf("=");
      return eq > 0 ? [{ id: raw.slice(0, eq), value: raw.slice(eq + 1) }] : [];
    }),
  };
}

/**
 * Which project to start in: the one named by `--project` (by id or by name),
 * or the only one there is. Ambiguity is a usage error rather than a guess,
 * because the wrong answer creates a branch in the wrong repo.
 */
function resolveProject(projects: ProjectDTO[], wanted?: string): string {
  if (wanted) {
    const hit = projects.find((p) => p.id === wanted || p.name === wanted);
    if (!hit) return failUsage(`unknown project: ${wanted}`);
    return hit.id;
  }
  if (projects.length === 1) return projects[0]!.id;
  if (projects.length === 0) return failUsage("no projects — add one with `makit serve --project <path>`");
  const names = projects.map((p) => p.name).join(", ");
  return failUsage(`several projects (${names}) — name one with --project`);
}

export interface SpawnedSession {
  sessionId: string;
  worktreePath: string;
  branch?: string;
}

/**
 * The worktree + spawn half of `new`, without the first message: `makit run`
 * (T17) needs to subscribe *between* the spawn and the message so it cannot miss
 * the turn it is about to wait for.
 */
export async function spawnFromArgs(client: MakitClient, args: NewArgs): Promise<SpawnedSession> {
  const projectId = resolveProject(await client.awaitProjects(), args.projectId);

  // D15: a worktree unless the user explicitly asked to stay put. A non-git
  // repo or an unborn HEAD degrades to the repo dir server-side, with a null
  // branch — which must be omitted rather than forwarded as null.
  let worktreePath = process.cwd();
  let branch: string | undefined;
  let created = false;
  if (!args.here) {
    const wt = await client.cmd("worktree.create", {
      projectId,
      branchName: args.branch ?? args.message,
      baseBranch: args.base,
    });
    worktreePath = String(wt.path);
    branch = typeof wt.branch === "string" ? wt.branch : undefined;
    created = true;
  }

  try {
    const spawned = await client.cmd("session.spawn", {
      projectId,
      agent: args.agent,
      worktreePath,
      branch,
      configOptions: args.configOptions.length ? args.configOptions : undefined,
    });
    return { sessionId: String(spawned.sessionId), worktreePath, branch };
  } catch (e) {
    // The worktree exists but the session it was for never will — and a refusal
    // here is not exotic: it is what D9's depth and fan-out bounds return, to a
    // caller that is typically an agent retrying. Without this the orphan trees
    // accumulate one per attempt, on the very path the bound exists to make
    // safe. `--here` is the user's own checkout and is never ours to remove.
    if (created) {
      // A rollback that fails is not the news; the refusal is.
      await client.cmd("worktree.remove", { projectId, worktreePath }).catch(() => {});
    }
    throw e;
  }
}

export async function runNew(argv: string[]): Promise<void> {
  const args = parseNewArgs(argv);
  await withClient(args, async (client) => {
    const { sessionId, worktreePath, branch } = await spawnFromArgs(client, args);

    // The first message is what promotes the draft; without one the session
    // stays pending, exactly as a session spawned from the app does.
    if (args.message !== undefined) {
      await client.cmd("send.message", { sessionId, text: args.message });
    }

    if (args.json) {
      console.log(JSON.stringify({ sessionId }));
      return;
    }
    const where = branch ? ` on ${branch}` : "";
    console.log(`[makit] session ${sessionId}${where}  ${worktreePath}`);
  });
}
