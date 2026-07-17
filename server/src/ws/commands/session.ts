/**
 * Session-domain `cmd` handlers (SPEC-19, moved verbatim from server.ts's
 * `buildCommandRouter`): send.message, session.action, cancel, session.kill,
 * session.spawn, agents.list, session.setAgent, session.list, session.attach.
 */

import { WireErrorCode } from "../../protocol/codec.js";
import { log } from "../../log.js";
import type { CommandRouter } from "../command_router.js";
import type { CommandDeps } from "./deps.js";

export function register(r: CommandRouter, deps: CommandDeps): void {
  const { manager, broadcastSnapshots, broadcastReposSnapshot } = deps;

  r.register("send.message", async (ctx) => {
    const sid = String(ctx.env.sessionId ?? "");
    const text = ctx.env.text;
    if (typeof text !== "string") {
      ctx.err(WireErrorCode.BadRequest, "send.message requires a string `text`");
      return;
    }
    const session = sid ? manager.getSession(sid) : undefined;
    // Log metadata only — never the message text, which can carry PII or
    // credentials.
    log.info(
      `[makit] send.message sid=${sid.slice(0, 8)} session=${!!session} textLen=${text.length}`,
    );
    if (!session) {
      ctx.err(WireErrorCode.NoSuchSession, "no such session");
      return;
    }
    ctx.ack();
    // A pending (draft) session materializes its worktree + agent on the
    // first real request, which names the branch. The manager routes any
    // promotion failure through the session's own event pipeline (a real,
    // persisted, monotonic `session.error`), so the handler just checks
    // whether to proceed and refreshes the repo snapshot on success.
    if (session.pending) {
      const started = await manager.promotePendingSession(session, text);
      if (!started) return;
      broadcastSnapshots();
      void broadcastReposSnapshot();
    }
    await session.sendUserMessage(text);
  });

  // Built-in control actions (e.g. /compact, /thinking) — NOT user turns.
  // Routed to the adapter's sendAction, which maps them to the agent's SDK
  // calls (e.g. pi's set_session_name). Adapters that can't map an action
  // ignore it.
  r.register("session.action", async (ctx) => {
    const sid = String(ctx.env.sessionId ?? "");
    const action = ctx.env.action;
    if (typeof action !== "string" || !action) {
      ctx.err(WireErrorCode.BadRequest, "session.action requires a string `action`");
      return;
    }
    const session = sid ? manager.getSession(sid) : undefined;
    if (!session) {
      ctx.err(WireErrorCode.NoSuchSession, "no such session");
      return;
    }
    const args =
      ctx.env.args && typeof ctx.env.args === "object" && !Array.isArray(ctx.env.args)
        ? (ctx.env.args as Record<string, unknown>)
        : undefined;
    ctx.ack();
    // Manual rename: reflect the new title in makit immediately, then let the
    // adapter persist it (pi's set_session_name).
    if (action === "name" && typeof args?.name === "string") {
      session.setTitle(args.name);
    }
    await session.sendAction(action, args);
  });

  r.register("cancel", async (ctx) => {
    const sid = String(ctx.env.sessionId ?? "");
    const session = sid ? manager.getSession(sid) : undefined;
    if (!session) {
      ctx.err(WireErrorCode.NoSuchSession, "no such session");
      return;
    }
    await session.adapter.cancel();
    ctx.ack();
  });

  r.register("session.kill", async (ctx) => {
    const sid = String(ctx.env.sessionId ?? "");
    try {
      await manager.killSession(sid);
    } catch {
      ctx.err(WireErrorCode.NoSuchSession, "no such session");
      return;
    }
    broadcastSnapshots();
    void broadcastReposSnapshot();
    ctx.ack();
  });

  r.register("session.spawn", async (ctx) => {
    const projectId = String(ctx.env.projectId ?? "");
    const agent = ctx.env.agent ? String(ctx.env.agent) : undefined;
    const baseBranch = ctx.env.baseBranch ? String(ctx.env.baseBranch) : undefined;
    // Optional: bind the draft to an EXISTING worktree so the first message
    // starts the agent there instead of forking a new one.
    const worktreePath = ctx.env.worktreePath ? String(ctx.env.worktreePath) : undefined;
    const branch = ctx.env.branch ? String(ctx.env.branch) : undefined;
    // New sessions are DRAFTS: the worktree + agent are deferred until the
    // first substantive message names the branch (see send.message). The
    // worktree forks off `baseBranch` (default branch when unset).
    const newSession = await manager.spawnPendingSession(projectId, agent, baseBranch, worktreePath, branch);
    // wireSession is invoked via the manager's "sessionCreated" listener
    // registered above — don't call it explicitly or every event fans out
    // twice.
    broadcastSnapshots();
    void broadcastReposSnapshot();
    ctx.ack({ sessionId: newSession.id });
  });

  r.register("session.spawnLinked", async (ctx) => {
    const sourceSessionId = String(ctx.env.sourceSessionId ?? "");
    if (!sourceSessionId) {
      ctx.err(WireErrorCode.BadRequest, "session.spawnLinked requires sourceSessionId");
      return;
    }
    // Split-pane flow: the new draft shares the source's worktree — its real
    // tree if started, else a virtual worktree both drafts materialize into.
    let newSession;
    try {
      newSession = await manager.spawnLinkedSession(sourceSessionId);
    } catch (e) {
      ctx.err(WireErrorCode.BadRequest, (e as Error).message);
      return;
    }
    broadcastSnapshots();
    void broadcastReposSnapshot();
    ctx.ack({ sessionId: newSession.id });
  });

  r.register("agents.list", async (ctx) => {
    ctx.ack({ agents: manager.listAgents() });
  });

  r.register("session.setAgent", async (ctx) => {
    const sessionId = String(ctx.env.sessionId ?? "");
    const agent = String(ctx.env.agent ?? "");
    if (!sessionId || !agent) {
      ctx.err(WireErrorCode.BadRequest, "session.setAgent requires sessionId and agent");
      return;
    }
    try {
      manager.setPendingAgent(sessionId, agent);
    } catch (e) {
      ctx.err(WireErrorCode.BadRequest, (e as Error).message);
      return;
    }
    broadcastSnapshots();
    ctx.ack();
  });

  r.register("session.list", async (ctx) => {
    const projectId = String(ctx.env.projectId ?? "");
    if (!projectId) {
      ctx.err(WireErrorCode.BadRequest, "session.list requires a projectId");
      return;
    }
    try {
      // Omit the server-internal filesystem `path` from the wire — the app
      // attaches by piSessionId and never needs the transcript path.
      const sessions = manager.listPiSessions(projectId).map(
        ({ path: _path, ...meta }) => meta,
      );
      ctx.ack({ sessions });
    } catch (e) {
      ctx.err(WireErrorCode.BadRequest, (e as Error).message);
    }
  });

  r.register("session.attach", async (ctx) => {
    // Re-attach a rehydrated (cold) makit session to its live agent after a
    // server restart. Back-compat: legacy clients send projectId+piSessionId
    // to attach a prior on-disk pi transcript instead.
    const sessionId = String(ctx.env.sessionId ?? "");
    if (sessionId) {
      try {
        const session = await manager.reattachSession(sessionId);
        broadcastSnapshots();
        ctx.ack({ sessionId: session.id });
      } catch (e) {
        ctx.err(WireErrorCode.BadRequest, (e as Error).message);
      }
      return;
    }
    const projectId = String(ctx.env.projectId ?? "");
    const piSessionId = String(ctx.env.piSessionId ?? "");
    if (!projectId || !piSessionId) {
      ctx.err(WireErrorCode.BadRequest, "session.attach requires projectId and piSessionId");
      return;
    }
    try {
      const session = await manager.attachPiSession(projectId, piSessionId);
      broadcastSnapshots();
      ctx.ack({ sessionId: session.id });
    } catch (e) {
      ctx.err(WireErrorCode.BadRequest, (e as Error).message);
    }
  });
}
