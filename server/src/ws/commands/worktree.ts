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
    // Same rename + one-release alias as `worktree.wrapUp` below. Benign here by
    // comparison (a wrong value forks from the wrong place, which is visible and
    // deletable) but kept consistent so there is one vocabulary on the wire.
    const targetBranch = ctx.env.targetBranch
      ? String(ctx.env.targetBranch)
      : ctx.env.baseBranch
        ? String(ctx.env.baseBranch)
        : undefined;
    const branchName = ctx.env.branchName ? String(ctx.env.branchName) : undefined;
    if (!projectId) {
      ctx.err(WireErrorCode.BadRequest, "worktree.create requires a projectId");
      return;
    }
    try {
      const wt = await manager.createWorktree(projectId, targetBranch, branchName);
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

  // A closed PR's worktree *and* its branch. Distinct from `worktree.remove`,
  // which keeps the branch (the sidebar and the mobile long-press use that one):
  // "remove this worktree" is a narrower request than "discard this dead line of
  // work". No base-branch leg — nothing landed, so there is nothing to catch up,
  // and the ack's `targetUpdated` is always false.
  r.register("worktree.discard", async (ctx) => {
    const projectId = String(ctx.env.projectId ?? "");
    const worktreePath = String(ctx.env.worktreePath ?? "");
    // What the client's confirm told the user would be deleted; refused on
    // mismatch, so the dialog and the deletion cannot disagree.
    const expectBranch = ctx.env.expectBranch ? String(ctx.env.expectBranch) : undefined;
    if (!projectId || !worktreePath) {
      ctx.err(WireErrorCode.BadRequest, "worktree.discard requires projectId and worktreePath");
      return;
    }
    try {
      const result = await manager.discardWorktree(projectId, worktreePath, expectBranch);
      void broadcastReposSnapshot();
      ctx.ack({ projectId, worktreePath, ...result });
    } catch (e) {
      ctx.err(WireErrorCode.BadRequest, (e as Error).message);
    }
  });

  // Ranked candidates for the "Lands in" picker. A read, so no broadcast: opening
  // a picker must not push a snapshot to every client.
  r.register("worktree.targetCandidates", async (ctx) => {
    const projectId = String(ctx.env.projectId ?? "");
    const worktreePath = String(ctx.env.worktreePath ?? "");
    if (!projectId || !worktreePath) {
      ctx.err(
        WireErrorCode.BadRequest,
        "worktree.targetCandidates requires projectId and worktreePath",
      );
      return;
    }
    try {
      const candidates = await manager.targetCandidates(projectId, worktreePath);
      ctx.ack({ projectId, worktreePath, candidates });
    } catch (e) {
      ctx.err(WireErrorCode.BadRequest, (e as Error).message);
    }
  });

  // Set the branch a worktree's work lands in: what the +/- diff measures against
  // (`git diff target...HEAD`, i.e. what a PR into it would contain), what
  // `gh pr create --base` will target, and what a wrap-up fast-forwards.
  //
  // Ordering is the whole contract here (R1/R2). The manager PERSISTS before we
  // broadcast, and we broadcast before we ack:
  //  * persisting after the broadcast would recompute the snapshot against the
  //    OLD target and ship stale numbers that then look correct until some
  //    unrelated event moved them;
  //  * acking before the broadcast is queued would let the client re-enable its
  //    picker while still painting the previous figures.
  // Deliberately NOT throttled: `throttledReposSnapshot` exists to coalesce
  // turn-end churn, and a user-initiated change must land immediately.
  r.register("worktree.setTarget", async (ctx) => {
    const projectId = String(ctx.env.projectId ?? "");
    const worktreePath = String(ctx.env.worktreePath ?? "");
    const targetBranch = ctx.env.targetBranch ? String(ctx.env.targetBranch) : "";
    if (!projectId || !worktreePath || !targetBranch) {
      ctx.err(
        WireErrorCode.BadRequest,
        "worktree.setTarget requires projectId, worktreePath and targetBranch",
      );
      return;
    }
    try {
      const result = await manager.setWorktreeTarget(projectId, worktreePath, targetBranch);
      void broadcastReposSnapshot();
      ctx.ack({ projectId, ...result });
    } catch (e) {
      ctx.err(WireErrorCode.BadRequest, (e as Error).message);
    }
  });

  // The ending a merged PR never had: remove the worktree, delete its branch, and
  // fast-forward the branch the PR landed on. `targetBranch` is the PR's own
  // baseRefName when the app has it; the manager falls back to the repo default.
  //
  // The ack carries what actually happened (which branch went, whether the base
  // moved and why not) because both the branch and base legs are best-effort — the
  // client has to be able to tell "tidied and caught up" from "tidied, base
  // untouched".
  r.register("worktree.wrapUp", async (ctx) => {
    const projectId = String(ctx.env.projectId ?? "");
    const worktreePath = String(ctx.env.worktreePath ?? "");
    // `targetBranch` is the name; `baseBranch` is read for ONE release as a
    // compatibility shim, and it is not cosmetic. A client that predates the
    // rename sends the old key, and the manager's `?? detectDefaultBranch()`
    // fallback would then silently fast-forward the WRONG branch and ack it as a
    // success -- the one irreversible failure in this rename. Delete the alias a
    // release after the app ships with the new key.
    const targetBranch = ctx.env.targetBranch
      ? String(ctx.env.targetBranch)
      : ctx.env.baseBranch
        ? String(ctx.env.baseBranch)
        : undefined;
    const expectBranch = ctx.env.expectBranch ? String(ctx.env.expectBranch) : undefined;
    if (!projectId || !worktreePath) {
      ctx.err(WireErrorCode.BadRequest, "worktree.wrapUp requires projectId and worktreePath");
      return;
    }
    try {
      const result = await manager.wrapUpWorktree(
        projectId,
        worktreePath,
        targetBranch,
        expectBranch,
      );
      void broadcastReposSnapshot();
      ctx.ack({ projectId, worktreePath, ...result });
    } catch (e) {
      ctx.err(WireErrorCode.BadRequest, (e as Error).message);
    }
  });

  // The PR mutations that act on GitHub rather than on disk. All rebroadcast the
  // repos snapshot: the gateway drops its cached lookup for the branch, so the
  // next poll reports the new draft/mergeStateStatus/state.
  for (const [kind, run] of [
    ["pr.markReady", (p: string, w: string) => manager.markPrReady(p, w)],
    ["pr.updateBranch", (p: string, w: string) => manager.updatePrBranch(p, w)],
    ["pr.squashMerge", (p: string, w: string) => manager.squashMergePr(p, w)],
  ] as const) {
    r.register(kind, async (ctx) => {
      const projectId = String(ctx.env.projectId ?? "");
      const worktreePath = String(ctx.env.worktreePath ?? "");
      if (!projectId || !worktreePath) {
        ctx.err(WireErrorCode.BadRequest, `${kind} requires projectId and worktreePath`);
        return;
      }
      try {
        await run(projectId, worktreePath);
        void broadcastReposSnapshot();
        ctx.ack({ projectId, worktreePath });
      } catch (e) {
        ctx.err(WireErrorCode.BadRequest, (e as Error).message);
      }
    });
  }
}
