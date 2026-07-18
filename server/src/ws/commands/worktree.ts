/**
 * Worktree-domain `cmd` handlers (SPEC-19, moved verbatim from server.ts's
 * `buildCommandRouter`): worktree.create, pr.list, worktree.createFromPr,
 * branch.rename, worktree.remove.
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

  r.register("pr.list", async (ctx) => {
    const projectId = String(ctx.env.projectId ?? "");
    if (!projectId) {
      ctx.err(WireErrorCode.BadRequest, "pr.list requires a projectId");
      return;
    }
    try {
      const prs = await manager.listOpenPrs(projectId);
      ctx.ack({ projectId, prs });
    } catch (e) {
      ctx.err(WireErrorCode.BadRequest, (e as Error).message);
    }
  });

  r.register("worktree.createFromPr", async (ctx) => {
    const projectId = String(ctx.env.projectId ?? "");
    const prNumber = Number(ctx.env.prNumber);
    if (!projectId || !Number.isInteger(prNumber)) {
      ctx.err(WireErrorCode.BadRequest, "worktree.createFromPr requires a projectId and prNumber");
      return;
    }
    try {
      const wt = await manager.createWorktreeFromPr(projectId, prNumber);
      void broadcastReposSnapshot();
      ctx.ack({ projectId, path: wt.path, branch: wt.branch });
    } catch (e) {
      ctx.err(WireErrorCode.BadRequest, (e as Error).message);
    }
  });

  r.register("branch.rename", async (ctx) => {
    const projectId = String(ctx.env.projectId ?? "");
    const worktreePath = String(ctx.env.worktreePath ?? "");
    const newName = String(ctx.env.newName ?? "").trim();
    if (!projectId || !worktreePath || !newName) {
      ctx.err(WireErrorCode.BadRequest, "branch.rename requires projectId, worktreePath and newName");
      return;
    }
    try {
      await manager.renameWorktreeBranch(projectId, worktreePath, newName);
      void broadcastReposSnapshot();
      ctx.ack({ projectId, worktreePath, branch: newName });
    } catch (e) {
      ctx.err(WireErrorCode.BadRequest, (e as Error).message);
    }
  });

  r.register("worktree.remove", async (ctx) => {
    const projectId = String(ctx.env.projectId ?? "");
    const worktreePath = String(ctx.env.worktreePath ?? "");
    if (!projectId || !worktreePath) {
      ctx.err(WireErrorCode.BadRequest, "worktree.remove requires projectId and worktreePath");
      return;
    }
    try {
      await manager.removeWorktree(projectId, worktreePath);
      void broadcastReposSnapshot();
      ctx.ack({ projectId, worktreePath });
    } catch (e) {
      ctx.err(WireErrorCode.BadRequest, (e as Error).message);
    }
  });
}
