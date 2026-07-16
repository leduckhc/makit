/**
 * Worktree-domain `cmd` handlers (SPEC-19, moved verbatim from server.ts's
 * `buildCommandRouter`): worktree.create.
 */

import { WireErrorCode } from "../../protocol/codec.js";
import type { CommandRouter } from "../command_router.js";
import type { CommandDeps } from "./deps.js";

export function register(r: CommandRouter, deps: CommandDeps): void {
  const { manager, broadcastReposSnapshot } = deps;

  r.register("worktree.create", async (ctx) => {
    const projectId = String(ctx.env.projectId ?? "");
    const baseBranch = ctx.env.baseBranch ? String(ctx.env.baseBranch) : undefined;
    if (!projectId) {
      ctx.err(WireErrorCode.BadRequest, "worktree.create requires a projectId");
      return;
    }
    try {
      const wt = await manager.createWorktree(projectId, baseBranch);
      void broadcastReposSnapshot();
      ctx.ack({ projectId, path: wt.path, branch: wt.branch });
    } catch (e) {
      ctx.err(WireErrorCode.BadRequest, (e as Error).message);
    }
  });
}
