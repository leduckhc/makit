/**
 * makit context-usage reporter for pi (SPEC-37) — pushes pi's own context-window
 * and cost readings to the makit server so the app can show them.
 *
 * Why an extension rather than protocol plumbing: makit drives pi over ACP, and
 * although ACP v1 defines a `usage_update` session update, **pi-acp never emits
 * one** (verified by enumerating every `sessionUpdate` literal in its shipped
 * `dist/index.js`). So there is nothing for the server's ACP mapper to receive,
 * and a pi session would show no usage at all. pi does expose the numbers
 * in-process via `ctx.getContextUsage()`, which is what this file forwards over
 * the loopback bridge makit already injects for `ctx.ui.*`.
 *
 * codex needs none of this: its app-server sends `thread/tokenUsage/updated`
 * natively (see `server/src/adapters/codex-map.ts`).
 *
 * Install (once):
 *   ln -s "$PWD/.pi/extensions/pi-usage" ~/.pi/agent/extensions/pi-usage
 *
 * Inert outside makit: with no `MAKIT_BRIDGE_*`/`MAKIT_SESSION_ID` in the
 * environment this file registers nothing, so a pi session in a plain terminal
 * is untouched.
 */

import {
  resolveBridge,
  buildUsage,
  isWorthSending,
  type PiContextUsage,
  type PiCost,
  type UsagePayload,
} from "./usage.js";

/**
 * The slice of pi's extension API this file uses. Declared locally rather than
 * imported from `@earendil-works/pi-coding-agent` so the extension typechecks
 * inside the makit server project, which does not depend on pi.
 */
interface PiHost {
  on(
    event: "message_end",
    handler: (
      event: { message?: { role?: string; usage?: { cost?: PiCost } } },
      ctx: { getContextUsage?: () => PiContextUsage | undefined | null },
    ) => void,
  ): void;
  log?(msg: string): void;
}

export default async function activate(pi: PiHost): Promise<void> {
  const bridge = resolveBridge(process.env);
  if (!bridge) return;

  let last: UsagePayload | undefined;

  pi.on("message_end", (event, ctx) => {
    if (event?.message?.role !== "assistant") return;
    const payload = buildUsage(ctx.getContextUsage?.(), event.message.usage?.cost);
    if (!payload || !isWorthSending(last, payload)) return;
    last = payload;

    // Fire-and-forget. A usage snapshot is strictly cosmetic, so a bridge that
    // has gone away (server restarted, session ended) must never surface as an
    // error in the user's pi session or delay the turn.
    void fetch(`${bridge.url}/usage`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${bridge.token}`,
      },
      body: JSON.stringify({ sessionId: bridge.sessionId, usage: payload }),
    }).catch((err: unknown) => {
      pi.log?.(`[usage] report failed (${(err as Error)?.message ?? err})`);
    });
  });
}
