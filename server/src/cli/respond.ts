/**
 * The shared `srv.response` sender behind `makit approve` and `makit answer`
 * (SPEC-cli-as-client U3). The terminal can now unblock a session it started but does not
 * have open on a screen.
 *
 * The flow, and why no server change is needed: connect → `sub {sessionId}` →
 * the server replays the session's pending `srv.request` (`server.ts:698`-`701`
 * calls `rpc.replayPendingTo` right after the `sub` ack) → we send the matching
 * `srv.response`. D13's two authorization rules stay entirely server-side
 * (`reverse_rpc.ts`): a response is refused from an agent-scoped token and from
 * any client outside the prompt's stored audience. This module adds no second
 * rule — it only mirrors D13(b) from the client side by answering **only** a
 * prompt for the session it named, never one that merely arrived on the socket.
 *
 * There is no long wait: a pending prompt (if any) follows the `sub` ack
 * immediately on the same socket, so a short grace after the ack is enough. No
 * prompt arriving means none is pending, and the verb exits non-zero rather
 * than blocking forever on a question the phone may have already answered.
 */
import { connectCli } from "./connect.js";

const SUB_ID = "sub";
/**
 * How long to wait after the `sub` ack for a replayed `srv.request`. The server
 * sends any pending prompt on the SAME socket immediately after the ack, so
 * this window only has to cover server-side ordering and network jitter, not a
 * human. 500ms is generous for that and still nowhere near a hang.
 */
const REPLAY_GRACE_MS = 500;
/**
 * A hard ceiling from the moment `sub` is sent, so a lost/absent `sub` ack can
 * never leave the verb blocked. In practice the ack always lands and the grace
 * above resolves the run first; this only guarantees the "never hang" property.
 */
const SUB_CEILING_MS = 5000;

export interface RespondArgs {
  host: string;
  port: number;
  sessionId: string;
}

export interface RespondSpec {
  /** The `srv.request` kinds this verb can answer correctly. */
  kinds: readonly string[];
  /** The verb to point at when the pending prompt is a kind we cannot answer. */
  instead: string;
  /** The response body for a prompt of an accepted kind. */
  build: (req: Record<string, unknown>) => Record<string, unknown>;
}

/**
 * Subscribe to `sessionId`, answer its one pending `srv.request` with the body
 * `build` derives from it (the exact shape `attach.ts` sends), then exit. Exits
 * non-zero when no prompt is pending, or on a `sub` error / disconnect.
 */
export async function respondToPrompt(args: RespondArgs, spec: RespondSpec): Promise<void> {
  const client = await connectCli(args);
  const sid = args.sessionId;
  let exitCode = 0;

  await new Promise<void>((resolve) => {
    let settled = false;
    let grace: NodeJS.Timeout | undefined;
    /**
     * Prompt kinds that arrived but this verb cannot answer correctly. Guessing is
     * not harmless: a text `value` sent to a `confirmAction` carries no `approved`
     * field, so the server reads it as a **deny** — the user types an answer and
     * unknowingly refuses the tool call.
     */
    const mismatched: string[] = [];
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(ceiling);
      if (grace) clearTimeout(grace);
      resolve();
    };
    const fail = (message: string) => {
      if (settled) return;
      console.error(`[makit] ${message} for session ${sid}`);
      exitCode = 1;
      finish();
    };
    const ceiling = setTimeout(() => fail("no pending prompt arrived"), SUB_CEILING_MS);

    client.onClose(() => fail("disconnected before a prompt could be answered"));
    client.onFrame((m) => {
      if (settled) return;
      if (m.t === "err") {
        fail(typeof m.message === "string" ? m.message : "request failed");
        return;
      }
      if (m.t === "srv.request") {
        // D13(b), client side: answer ONLY a prompt for the session we named,
        // never one that merely arrived on this socket.
        if (m.sessionId !== sid) return;
        const kind = typeof m.kind === "string" ? m.kind : "";
        // The id is what correlates the answer to the pending request. Taken
        // unchecked, a frame without one produced a response whose `id` was
        // dropped by JSON.stringify: the server could match it to nothing, so the
        // answer vanished while the verb reported success — the human believes
        // they approved a tool call that is still waiting.
        const promptId = typeof m.id === "string" && m.id.length > 0 ? m.id : undefined;
        if (promptId === undefined) {
          fail("the pending prompt arrived without an id, so it cannot be answered");
          return;
        }
        // A session can have several prompts pending, and the replay order is not
        // ours to choose. Remember a kind we cannot answer and keep listening until
        // the grace window closes — failing on the first mismatch made arrival order
        // decide whether the verb worked, and told the user to use the other verb
        // while an answerable prompt was still on its way.
        if (!spec.kinds.includes(kind)) {
          if (!mismatched.includes(kind)) mismatched.push(kind);
          return;
        }
        // Close only once the response is on the wire, so teardown does not
        // terminate the socket before it flushes. The body is spread FIRST so the
        // envelope (`t`/`id`/`kind`) always wins — that is what routes and
        // correlates the frame, so it is not the part a body may rewrite.
        client.send({ ...spec.build(m), t: "srv.response", id: promptId, kind }, finish);
        return;
      }
      // The pending prompt (if any) follows this ack immediately; a short grace
      // is all the wait we ever do.
      if (m.t === "ack" && m.id === SUB_ID) {
        grace = setTimeout(() => {
          if (mismatched.length > 0) {
            fail(
              `the pending prompt is a ${mismatched.join("/")} — answer it with \`makit ${spec.instead}\``,
            );
            return;
          }
          fail("no pending prompt");
        }, REPLAY_GRACE_MS);
      }
    });

    client.send({ t: "sub", id: SUB_ID, sessionId: sid });
  });

  client.close();
  if (exitCode !== 0) process.exit(exitCode);
}
