/**
 * Session-domain `cmd` handlers (SPEC-19, moved verbatim from server.ts's
 * `buildCommandRouter`): send.message, session.action, cancel, session.kill,
 * session.spawn, agents.list, session.setAgent, session.list, session.attach.
 */

import { WireErrorCode } from "../../protocol/codec.js";
import type { ApprovalPolicy, SessionOrigin } from "../../protocol.js";
import { isAgentScoped } from "../principal.js";
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
 * SPEC-46 C3: `session.transcript` clamps `limit` to this window. A bounded
 * tail is the whole point of the command (D5) — an unbounded slice would defeat
 * it — and 200 is generous for the "quote the last few turns" use it serves.
 */
const MIN_TRANSCRIPT_LIMIT = 1;
const MAX_TRANSCRIPT_LIMIT = 200;

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
    // Backstop for the `sub`-triggered re-attach: a message can race ahead of it
    // (reconnect resubscribe + a queued message), and no input may be answered
    // with the cold-session error while a resume is still possible. Collapses
    // onto the same in-flight re-attach rather than starting a second agent.
    await manager.ensureLive(sid);
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
    // SPEC-35: stop means stop. Pending mid-turn messages are dropped rather
    // than fired into the context the user just aborted.
    session.clearQueue();
    await session.adapter.cancel();
    ctx.ack();
  });

  /**
   * Drop ONE pending mid-turn message (SPEC-35). An id the server no longer
   * holds is a race the user cannot avoid — the message was flushed between the
   * tap and this frame — so it acks instead of erroring.
   */
  r.register("queue.cancel", async (ctx) => {
    const sid = String(ctx.env.sessionId ?? "");
    const session = sid ? manager.getSession(sid) : undefined;
    if (!session) {
      ctx.err(WireErrorCode.NoSuchSession, "no such session");
      return;
    }
    // `queuedId`, not `id`: the app's Envelope spreads the command body OVER the
    // frame's own `id`, so a body field called `id` silently replaces the request
    // id and no ack can ever be correlated with its command.
    const id = ctx.env.queuedId;
    if (typeof id !== "string" || !id) {
      ctx.err(WireErrorCode.BadRequest, "queue.cancel requires a string `queuedId`");
      return;
    }
    session.cancelQueued(id);
    ctx.ack();
  });

  /**
   * Edit a pending mid-turn message (SPEC-38). Empty text cancels it. A stale id
   * (the message flushed between the tap and this frame) acks like
   * `queue.cancel`; a missing `text` is a real client bug and errors.
   */
  r.register("queue.update", async (ctx) => {
    const sid = String(ctx.env.sessionId ?? "");
    const session = sid ? manager.getSession(sid) : undefined;
    if (!session) {
      ctx.err(WireErrorCode.NoSuchSession, "no such session");
      return;
    }
    // See queue.cancel: the message id travels as `queuedId` so it cannot
    // clobber the frame's request id.
    const id = ctx.env.queuedId;
    const text = ctx.env.text;
    if (typeof id !== "string" || !id) {
      ctx.err(WireErrorCode.BadRequest, "queue.update requires a string `queuedId`");
      return;
    }
    if (typeof text !== "string") {
      ctx.err(WireErrorCode.BadRequest, "queue.update requires a string `text`");
      return;
    }
    session.updateQueued(id, text);
    ctx.ack();
  });

  /**
   * Send ONE pending message now (SPEC-39 — the tray's ⤒): interrupt the running
   * turn so the promoted message is delivered next, keeping the rest queued.
   *
   * This is `cancel`'s per-message opposite, so it must not borrow its
   * queue-clearing: a stale id (flushed between the tap and this frame) acks
   * without aborting anything, because interrupting a turn the user did not
   * choose to stop destroys work. A missing id is a real client bug.
   */
  r.register("queue.promote", async (ctx) => {
    const sid = String(ctx.env.sessionId ?? "");
    const session = sid ? manager.getSession(sid) : undefined;
    if (!session) {
      ctx.err(WireErrorCode.NoSuchSession, "no such session");
      return;
    }
    // `queuedId`, not `id`: the app's Envelope spreads the command body OVER the
    // frame's own `id`, so a body field called `id` silently replaces the request
    // id and no ack can ever be correlated with its command.
    const id = ctx.env.queuedId;
    if (typeof id !== "string" || !id) {
      ctx.err(WireErrorCode.BadRequest, "queue.promote requires a string `queuedId`");
      return;
    }
    await session.promoteQueued(id);
    ctx.ack();
  });

  /**
   * Reorder the pending messages (SPEC-38). `ids` is a hint — see
   * `Session.reorderQueue`: a queue that flushed under the user cannot make this
   * fail, so only a non-array `ids` is an error.
   */
  r.register("queue.reorder", async (ctx) => {
    const sid = String(ctx.env.sessionId ?? "");
    const session = sid ? manager.getSession(sid) : undefined;
    if (!session) {
      ctx.err(WireErrorCode.NoSuchSession, "no such session");
      return;
    }
    const raw = ctx.env.ids;
    if (!Array.isArray(raw)) {
      ctx.err(WireErrorCode.BadRequest, "queue.reorder requires an array `ids`");
      return;
    }
    session.reorderQueue(raw.filter((v): v is string => typeof v === "string"));
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

  // SPEC-46 C3 (D5): a BOUNDED transcript slice for `makit handoff --carry`.
  // The last `limit` events, oldest-first, served from the event store (not the
  // session's in-memory cache) and returned VERBATIM — the same wire shape as
  // fanout, no projection (D7). Rendering the slice into a fenced block is CLI
  // work, not the server's.
  r.register("session.transcript", async (ctx) => {
    const sid = String(ctx.env.sessionId ?? "");
    const rawLimit = ctx.env.limit;
    if (typeof rawLimit !== "number" || !Number.isFinite(rawLimit)) {
      ctx.err(WireErrorCode.BadRequest, "session.transcript requires a numeric `limit`");
      return;
    }
    const session = sid ? manager.getSession(sid) : undefined;
    if (!session) {
      ctx.err(WireErrorCode.NoSuchSession, "no such session");
      return;
    }
    const limit = Math.max(
      MIN_TRANSCRIPT_LIMIT,
      Math.min(MAX_TRANSCRIPT_LIMIT, Math.floor(rawLimit)),
    );
    // `slice(-limit)` is the last `limit`, oldest-first, and returns the whole
    // log when it is shorter than `limit`.
    const events = manager.readTranscript(sid);
    ctx.ack({ events: events.slice(-limit) });
  });

  r.register("session.spawn", async (ctx) => {
    // SPEC-46 D9/D10: lineage is derived from the credential, NEVER from the
    // wire. An agent-scoped token's parent IS its own session; a body
    // `parentId` naming a different session is a forgery attempt and refused
    // (not silently honoured, not silently overwritten). A human client (phone
    // or CLI) carries no session, so it spawns a root and any body `parentId`
    // is ignored — the wire is never a lineage source.
    const principal = ctx.client.principal;
    const bodyParentId = ctx.env.parentId ? String(ctx.env.parentId) : undefined;
    const handoffReason = ctx.env.handoffReason ? String(ctx.env.handoffReason) : undefined;
    let parentId: string | undefined;
    let origin: SessionOrigin;
    if (isAgentScoped(principal)) {
      parentId = principal!.sessionId!;
      if (bodyParentId !== undefined && bodyParentId !== parentId) {
        ctx.err(
          WireErrorCode.BadRequest,
          "session.spawn parentId is derived from the calling session and cannot name a different session",
        );
        return;
      }
      origin = "agent";
      // SPEC-46 D9/T11: depth + live-child count are recomputed server-side from
      // persisted lineage; the forgeable MAKIT_SPAWN_DEPTH is display-only.
      const boundError = manager.checkSpawnBounds(parentId);
      if (boundError) {
        ctx.err(WireErrorCode.BadRequest, boundError);
        return;
      }
    } else {
      // The `client` cap marks the CLI (D2); a full-access principal (no caps)
      // is the app/phone. This is the only app-vs-CLI signal the wire carries.
      parentId = undefined;
      origin = principal?.caps?.includes("client") ? "cli" : "app";
    }
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
    // SPEC-46 D13: the approval policy may be RELAXED (`yolo`) only by a human
    // credential. An agent setting `yolo` would be granting itself the
    // unsupervised shell access the audience ladder exists to keep under a
    // human's eye, so it is refused (not silently downgraded). A stricter
    // policy from an agent is harmless and allowed; an unknown value is
    // dropped so the session falls back to the default (`ask-on-risky`).
    const VALID_POLICIES: readonly ApprovalPolicy[] = ["yolo", "ask-on-risky", "ask-always"];
    const requestedPolicy = ctx.env.policy ? String(ctx.env.policy) : undefined;
    if (requestedPolicy === "yolo" && isAgentScoped(principal)) {
      ctx.err(
        WireErrorCode.BadRequest,
        "session.spawn policy 'yolo' may only be set by a human credential, not an agent token",
      );
      return;
    }
    const policy = VALID_POLICIES.includes(requestedPolicy as ApprovalPolicy)
      ? (requestedPolicy as ApprovalPolicy)
      : undefined;
    // New sessions are DRAFTS: the agent is deferred until the first
    // substantive message names the session (see send.message).
    const newSession = await manager.spawnPendingSession(projectId, agent, worktreePath, branch, configOptions, {
      parentId,
      handoffReason,
      origin,
    }, policy);
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
