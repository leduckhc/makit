/**
 * Session-domain `cmd` handlers (SPEC-19, moved verbatim from server.ts's
 * `buildCommandRouter`): send.message, session.action, cancel, session.kill,
 * session.spawn, agents.list, session.setAgent, session.list, session.attach.
 */

import { WireErrorCode } from "../../protocol/codec.js";
import { log } from "../../log.js";
import {
  isMediaId,
  sharedMediaStore,
  type MediaAttachment,
  type MediaStore,
} from "../../media/store.js";
import type { CommandRouter } from "../command_router.js";
import type { CommandDeps } from "./deps.js";

/** Per-message attachment cap (SPEC-33 §3.3). A prompt, not a gallery. */
export const MAX_ATTACHMENTS = 8;

/**
 * Label handed to `promotePendingSession` when an image-only turn promotes a
 * draft session. The first message names the branch/worktree, and "" would
 * produce an unusable name.
 */
const IMAGE_ONLY_LABEL = "attachment";

/**
 * Outcome of {@link parseAttachments}. A union rather than a value-or-marker
 * because there are four distinct outcomes, two of which the user must be told
 * about: nothing attached (`ok`, no `attachments`), some resolved, and the two
 * refusals below.
 */
export type ParsedAttachments =
  | { ok: true; attachments?: MediaAttachment[] }
  | { ok: false; reason: "unresolved" | "too_many" };

/**
 * Resolve the wire `attachments` array against the media store (SPEC-33 §3.3).
 *
 * Two failure modes, treated differently on purpose:
 *
 * - **Malformed entries are dropped**, matching {@link parseConfigPicks}. A
 *   client that sends junk gets the well-formed remainder.
 * - **A well-formed id the store cannot resolve is a refusal.** Dropping it would
 *   turn "why is this button misaligned?" into a bare text prompt and leave the
 *   user reading a reply about nothing. An expired or GC'd upload must be
 *   visible, so this reports `"unresolved"` and the handler refuses the turn.
 *
 * `attachments` is left absent (not empty) when there is nothing to attach, so
 * the adapter contract stays "absent means absent".
 */
export function parseAttachments(raw: unknown, store: MediaStore): ParsedAttachments {
  if (!Array.isArray(raw)) return { ok: true };
  const wanted: { mediaId: string; name?: string }[] = [];
  for (const entry of raw) {
    if (!entry || typeof entry !== "object") continue;
    const { mediaId, name } = entry as { mediaId?: unknown; name?: unknown };
    if (typeof mediaId !== "string" || !isMediaId(mediaId)) continue;
    wanted.push(typeof name === "string" && name ? { mediaId, name } : { mediaId });
  }
  if (wanted.length === 0) return { ok: true };
  if (wanted.length > MAX_ATTACHMENTS) return { ok: false, reason: "too_many" };

  const resolved: MediaAttachment[] = [];
  for (const { mediaId, name } of wanted) {
    const descriptor = store.stat(mediaId);
    if (!descriptor) return { ok: false, reason: "unresolved" };
    resolved.push(name ? { ...descriptor, name } : descriptor);
  }
  return { ok: true, attachments: resolved };
}

/**
 * Parse the optional `session.spawn` `configOptions` picks from the wire:
 * an array of `{id, value}` where `value` is a string or boolean. Anything
 * malformed is dropped here; semantic validation (against the cached catalog)
 * happens in the manager (SPEC-27).
 */
function parseConfigPicks(
  raw: unknown,
): { id: string; value: string | boolean }[] | undefined {
  if (!Array.isArray(raw)) return undefined;
  const picks: { id: string; value: string | boolean }[] = [];
  for (const entry of raw) {
    if (!entry || typeof entry !== "object") continue;
    const { id, value } = entry as { id?: unknown; value?: unknown };
    if (typeof id !== "string" || !id) continue;
    if (typeof value !== "string" && typeof value !== "boolean") continue;
    picks.push({ id, value });
  }
  return picks.length > 0 ? picks : undefined;
}

export function register(r: CommandRouter, deps: CommandDeps): void {
  const { manager, broadcastSnapshots, broadcastReposSnapshot } = deps;

  r.register("send.message", async (ctx) => {
    const sid = String(ctx.env.sessionId ?? "");
    const text = ctx.env.text;
    if (typeof text !== "string") {
      ctx.err(WireErrorCode.BadRequest, "send.message requires a string `text`");
      return;
    }
    // SPEC-33: images the user attached. Resolved here, so an adapter never sees
    // an id it cannot turn into bytes.
    const parsed = parseAttachments(ctx.env.attachments, deps.media ?? sharedMediaStore());
    if (!parsed.ok) {
      ctx.err(
        WireErrorCode.BadRequest,
        parsed.reason === "too_many"
          ? `send.message accepts at most ${MAX_ATTACHMENTS} attachments`
          : "send.message names an attachment that is no longer stored — re-upload it",
      );
      return;
    }
    const attachments = parsed.attachments;
    const session = sid ? manager.getSession(sid) : undefined;
    // Log metadata only — never the message text, which can carry PII or
    // credentials, and never an attachment's id or name.
    log.info(
      `[makit] send.message sid=${sid.slice(0, 8)} session=${!!session} textLen=${text.length} attachments=${attachments?.length ?? 0}`,
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
      // An image-only turn has no text to name the branch after, so promotion
      // gets a fallback label rather than "".
      const label = text.trim() || (attachments?.length ? IMAGE_ONLY_LABEL : text);
      const started = await manager.promotePendingSession(session, label);
      if (!started) return;
      broadcastSnapshots();
      void broadcastReposSnapshot();
    }
    await session.sendUserMessage(text, attachments);
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

  // Archive (SPEC-29): hide from the active list but keep it resumable. The
  // fresh snapshot omits archived sessions; unarchive restores it.
  r.register("session.archive", async (ctx) => {
    const sid = String(ctx.env.sessionId ?? "");
    try {
      await manager.archiveSession(sid);
    } catch {
      ctx.err(WireErrorCode.NoSuchSession, "no such session");
      return;
    }
    broadcastSnapshots();
    void broadcastReposSnapshot();
    ctx.ack();
  });

  r.register("session.unarchive", async (ctx) => {
    const sid = String(ctx.env.sessionId ?? "");
    try {
      await manager.unarchiveSession(sid);
    } catch {
      ctx.err(WireErrorCode.NoSuchSession, "no such session");
      return;
    }
    broadcastSnapshots();
    void broadcastReposSnapshot();
    ctx.ack();
  });

  // Return the archived sessions (SPEC-29) for the "Show archived" list. Unlike
  // the active `sessions.snapshot` (which omits them), this is an explicit
  // request/ack so archived sessions only load when the user asks.
  r.register("session.listArchived", async (ctx) => {
    ctx.ack({ sessions: await manager.listArchivedSessions() });
  });

  r.register("session.spawn", async (ctx) => {
    const projectId = String(ctx.env.projectId ?? "");
    const agent = ctx.env.agent ? String(ctx.env.agent) : undefined;
    // The worktree the client resolved (creating it first when the user asked
    // for a new branch / a PR): the first message starts the agent there.
    const worktreePath = ctx.env.worktreePath ? String(ctx.env.worktreePath) : undefined;
    const branch = ctx.env.branch ? String(ctx.env.branch) : undefined;
    // Optional pre-spawn config picks (SPEC-27): [{id, value}] validated against
    // the cached catalog by the manager (unknown ids/values dropped) and applied
    // at first-message launch.
    const configOptions = parseConfigPicks(ctx.env.configOptions);
    // New sessions are DRAFTS: the agent is deferred until the first
    // substantive message names the session (see send.message).
    const newSession = await manager.spawnPendingSession(projectId, agent, worktreePath, branch, configOptions);
    // wireSession is invoked via the manager's "sessionCreated" listener
    // registered above — don't call it explicitly or every event fans out
    // twice.
    broadcastSnapshots();
    void broadcastReposSnapshot();
    ctx.ack({ sessionId: newSession.id });
  });

  r.register("agents.list", async (ctx) => {
    ctx.ack({ agents: await manager.listAgentsWithCapabilities() });
  });

  r.register("agents.refresh", async (ctx) => {
    const agent = String(ctx.env.agent ?? "");
    if (!agent) {
      ctx.err(WireErrorCode.BadRequest, "agents.refresh requires an `agent`");
      return;
    }
    const descriptor = await manager.refreshAgent(agent);
    if (!descriptor) {
      ctx.err(WireErrorCode.BadRequest, `unknown agent: ${agent}`);
      return;
    }
    ctx.ack({ agent: descriptor });
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
      // Adapter-native discovery (SPEC-29): ask each available agent over its
      // own protocol (ACP `session/list`, codex `thread/list`) instead of
      // scraping pi transcript files. Already omits the server-internal path.
      const sessions = await manager.listAgentSessions(projectId);
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
