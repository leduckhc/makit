/**
 * Docs-domain `cmd` handlers (SPEC-46): `docs.watch`, `docs.read`,
 * `docs.publish`, `docs.unpublish`, `docs.grants`.
 *
 * `docs.watch` mirrors `ports.watch` exactly — a ref-counted flag that gates the
 * doc index (nothing is walked while no client watches), with the cached
 * snapshot handed over once on a false→true transition so a freshly-mounted
 * screen paints immediately. The flag is cleared on socket close in `server.ts`.
 *
 * The other four are request/reply: `docs.read` returns markdown text (and
 * errors for HTML — D7); `docs.publish` returns a grant or a stated reason
 * (D15); `docs.unpublish` revokes; `docs.grants` enumerates the shares.
 */

import { WireErrorCode } from "../../protocol/codec.js";
import type { CommandRouter } from "../command_router.js";
import type { CommandDeps } from "./deps.js";

export function register(r: CommandRouter, deps: CommandDeps): void {
  r.register("docs.watch", async (ctx) => {
    ctx.ack();
    // A malformed payload is a NO-OP (as in ports.watch): only a real boolean
    // toggles the flag. Coercing a non-boolean to `false` would let `{on:"yes"}`
    // silently turn a watching client OFF and stop the index re-walking.
    const on = ctx.env.on;
    if (typeof on !== "boolean") return;
    const wasWatching = ctx.client.watchingDocs === true;
    ctx.client.watchingDocs = on;
    deps.onDocsWatchersChanged();
    // Cached snapshot only on a false → true transition — a re-sent {on:true}
    // (reconnect, rebuild) must neither re-send it nor re-walk.
    if (on && !wasWatching) deps.sendDocsSnapshot(ctx.client);
  });

  r.register("docs.read", async (ctx) => {
    const worktreePath = ctx.env.worktreePath;
    const relPath = ctx.env.relPath;
    if (typeof worktreePath !== "string" || typeof relPath !== "string") {
      ctx.err(WireErrorCode.BadRequest, "docs.read requires worktreePath and relPath");
      return;
    }
    const result = deps.docs.read(worktreePath, relPath);
    if (result.ok) ctx.ack({ text: result.text });
    else ctx.err(WireErrorCode.BadRequest, result.message);
  });

  r.register("docs.publish", async (ctx) => {
    const worktreePath = ctx.env.worktreePath;
    const relPath = ctx.env.relPath;
    if (typeof worktreePath !== "string" || typeof relPath !== "string") {
      ctx.err(WireErrorCode.BadRequest, "docs.publish requires worktreePath and relPath");
      return;
    }
    const result = await deps.docs.publish(worktreePath, relPath);
    // Degrade loudly (D15): a failure carries a human reason, never a dead URL.
    if (result.ok) ctx.ack({ grant: result.grant });
    else ctx.err(WireErrorCode.BadRequest, result.reason);
  });

  r.register("docs.open", async (ctx) => {
    // D8 rev 2: local clients get direct OS opener; remote clients must publish.
    if (!ctx.client.isLocal) {
      ctx.err(WireErrorCode.BadRequest, "docs.open is for local clients only; remote clients must publish");
      return;
    }
    const worktreePath = ctx.env.worktreePath;
    const relPath = ctx.env.relPath;
    if (typeof worktreePath !== "string" || typeof relPath !== "string") {
      ctx.err(WireErrorCode.BadRequest, "docs.open requires worktreePath and relPath");
      return;
    }
    // Degrade loudly, as publish does: say why, never a bare failure.
    const result = await deps.docs.open(worktreePath, relPath);
    if (result.ok) ctx.ack({ ok: true });
    else ctx.err(WireErrorCode.BadRequest, result.reason);
  });

  r.register("docs.unpublish", async (ctx) => {
    const grantId = ctx.env.grantId;
    if (typeof grantId !== "string") {
      ctx.err(WireErrorCode.BadRequest, "docs.unpublish requires grantId");
      return;
    }
    // Idempotent by design: revoking an already-gone grant still acks {ok}.
    deps.docs.unpublish(grantId);
    ctx.ack({ ok: true });
  });

  r.register("docs.grants", async (ctx) => {
    ctx.ack({ grants: deps.docs.grants() });
  });
}
