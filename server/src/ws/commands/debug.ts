/**
 * Dev-only debug `cmd` handlers (SPEC-decomposition-and-dedup, moved verbatim from server.ts's
 * `registerDebugCommands`): debug.ask, debug.ask-multi. Registered only when
 * MAKIT_DEV is set.
 */

import { WireErrorCode } from "../../protocol/codec.js";
import { log } from "../../log.js";
import type { CommandRouter } from "../command_router.js";
import type { CommandDeps } from "./deps.js";

export function register(r: CommandRouter, deps: CommandDeps): void {
  const { manager, askDevice } = deps;

  r.register("debug.ask", async (ctx) => {
    ctx.ack();
    const resp = await askDevice({
      kind: "askUserQuestion",
      questions: [
        {
          header: "Test",
          question: String(ctx.env.question ?? "Pick one"),
          options: [
            { label: "Yes" },
            { label: "No" },
            { label: "Maybe", description: "If you must" },
          ],
        },
      ],
    });
    log.info(`[makit] debug.ask answered: ${JSON.stringify(resp)}`);
  });

  r.register("debug.ask-multi", async (ctx) => {
    const sid = String(ctx.env.sessionId ?? "");
    const session = sid ? manager.getSession(sid) : undefined;
    if (!session) {
      ctx.err(WireErrorCode.NoSuchSession, "no such session");
      return;
    }
    ctx.ack();
    const resp = await askDevice(
      {
        kind: "askUserQuestion",
        questions: [
          {
            header: "Language",
            question: "Which language?",
            options: [{ label: "Dart" }, { label: "TypeScript" }],
            recommended: 0,
          },
          {
            header: "Tools",
            question: "Which tools?",
            multi: true,
            options: [{ label: "Simulator" }, { label: "Server" }, { label: "Logs" }],
          },
        ],
      },
      { sessionId: sid },
    );
    log.info(`[makit] debug.ask-multi answered: ${JSON.stringify(resp)}`);
    session.adapter.emit("event", {
      ts: Date.now(),
      kind: "agent.message",
      payload: { text: JSON.stringify(resp) },
    });
  });
}
