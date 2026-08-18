/**
 * Project-domain `cmd` handlers (SPEC-decomposition-and-dedup, moved verbatim from server.ts's
 * `buildCommandRouter`): project.browse, project.add, project.remove.
 */

import { existsSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { resolve } from "node:path";
import { WireErrorCode } from "../../protocol/codec.js";
import { browseDirectory } from "../../project-store.js";
import type { CommandRouter } from "../command_router.js";
import type { CommandDeps } from "./deps.js";

export function register(r: CommandRouter, deps: CommandDeps): void {
  const { manager, broadcastSnapshots, broadcastReposSnapshot } = deps;

  r.register("project.browse", async (ctx) => {
    const raw = ctx.env.path;
    const path = typeof raw === "string" && raw.length > 0 ? raw : homedir();
    try {
      ctx.ack({ ...browseDirectory(path) });
    } catch (e) {
      ctx.err(WireErrorCode.BadRequest, (e as Error).message);
    }
  });

  r.register("project.add", async (ctx) => {
    const path = typeof ctx.env.path === "string" ? ctx.env.path : "";
    if (!path) {
      ctx.err(WireErrorCode.BadRequest, "project.add requires a string `path`");
      return;
    }
    const full = resolve(path);
    if (!existsSync(full) || !statSync(full).isDirectory()) {
      ctx.err(WireErrorCode.BadRequest, `not a directory: ${full}`);
      return;
    }
    const project = manager.addProject(full);
    broadcastSnapshots();
    await broadcastReposSnapshot();
    ctx.ack({ projectId: project.id });
  });

  r.register("project.remove", async (ctx) => {
    const projectId = typeof ctx.env.projectId === "string" ? ctx.env.projectId : "";
    if (!projectId) {
      ctx.err(WireErrorCode.BadRequest, "project.remove requires a string `projectId`");
      return;
    }
    try {
      manager.removeProject(projectId);
    } catch (e) {
      ctx.err(WireErrorCode.BadRequest, (e as Error).message);
      return;
    }
    broadcastSnapshots();
    await broadcastReposSnapshot();
    ctx.ack({});
  });
}
