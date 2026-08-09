/**
 * `makit new` — start a session from the terminal (SPEC-46 T12).
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
import { connectCli } from "./connect.js";
import { EXIT_USAGE } from "./exit-codes.js";
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

export function parseNewArgs(argv: string[]): NewArgs {
  const a: NewArgs = { host: "127.0.0.1", port: 7777, here: false, json: false, configOptions: [] };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i]!;
    if (t === "--host") a.host = String(argv[++i]);
    else if (t === "--port") a.port = Number(argv[++i]);
    else if (t === "-m" || t === "--message") a.message = String(argv[++i]);
    else if (t === "--agent") a.agent = String(argv[++i]);
    else if (t === "--project") a.projectId = String(argv[++i]);
    else if (t === "--branch") a.branch = String(argv[++i]);
    else if (t === "--base") a.base = String(argv[++i]);
    else if (t === "--here") a.here = true;
    else if (t === "--json") a.json = true;
    else if (t === "--config") {
      const raw = String(argv[++i] ?? "");
      const eq = raw.indexOf("=");
      if (eq > 0) a.configOptions.push({ id: raw.slice(0, eq), value: raw.slice(eq + 1) });
    }
  }
  return a;
}

function failUsage(message: string): never {
  console.error(`[makit] ${message}`);
  return process.exit(EXIT_USAGE);
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

export async function runNew(argv: string[]): Promise<void> {
  const args = parseNewArgs(argv);
  const client = await connectCli(args);
  try {
    const projectId = resolveProject(await client.awaitProjects(), args.projectId);

    // D15: a worktree unless the user explicitly asked to stay put. A non-git
    // repo or an unborn HEAD degrades to the repo dir server-side, with a null
    // branch — which must be omitted rather than forwarded as null.
    let worktreePath = process.cwd();
    let branch: string | undefined;
    if (!args.here) {
      const created = await client.cmd("worktree.create", {
        projectId,
        branchName: args.branch ?? args.message,
        baseBranch: args.base,
      });
      worktreePath = String(created.path);
      branch = typeof created.branch === "string" ? created.branch : undefined;
    }

    const spawned = await client.cmd("session.spawn", {
      projectId,
      agent: args.agent,
      worktreePath,
      branch,
      configOptions: args.configOptions.length ? args.configOptions : undefined,
    });
    const sessionId = String(spawned.sessionId);

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
  } finally {
    client.close();
  }
}
