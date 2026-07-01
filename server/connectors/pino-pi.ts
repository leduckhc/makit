/**
 * pino-pi — agent connector for `pi`.
 *
 * Loaded into pi via `pi --mode rpc -e <this-file>` by pino's PiAdapter.
 * Translates pi's native tool calls into pino's canonical UICall envelope
 * and ships them to the phone via the loopback HTTP bridge.
 *
 * Env contract (set by PiAdapter):
 *   PINO_BRIDGE_URL    — loopback bridge base URL
 *   PINO_BRIDGE_TOKEN  — shared secret for the bridge
 *   PINO_SESSION_ID    — sessionId used to route srv.request to the right
 *                        subscribed clients
 *
 * To write a new connector for another agent (claude / codex / piano):
 *   1. Copy this file into server/connectors/.
 *   2. Replace the registerTool({...}) calls with your agent's equivalent.
 *   3. In execute(), translate the agent-native params into one of the
 *      canonical UICall variants from `../src/uicall.ts`.
 *   4. pino auto-loads every `.ts` file in server/connectors/.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import type { UICall, UIResponse } from "../src/uicall.js";

const BRIDGE_URL = process.env.PINO_BRIDGE_URL;
const BRIDGE_TOKEN = process.env.PINO_BRIDGE_TOKEN;
const SESSION_ID = process.env.PINO_SESSION_ID;

/** Post a UICall to the loopback bridge, await the user's response. */
async function uicall(call: UICall): Promise<UIResponse> {
  const res = await fetch(`${BRIDGE_URL}/uicall`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${BRIDGE_TOKEN}`,
    },
    body: JSON.stringify({ sessionId: SESSION_ID, ...call }),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`pino-pi: bridge returned ${res.status}: ${text}`);
  }
  return (await res.json()) as UIResponse;
}

export default function (pi: ExtensionAPI) {
  if (!BRIDGE_URL || !BRIDGE_TOKEN) return; // not running under pino

  const questionsParam = Type.Object({
    questions: Type.Array(
      Type.Object({
        header: Type.Optional(
          Type.String({
            description: "Short label (max ~12 chars) shown in the dialog header.",
          }),
        ),
        question: Type.String({ description: "The question to display." }),
        options: Type.Array(
          Type.Object({
            label: Type.String({ description: "Option label (1–5 words)." }),
            description: Type.Optional(Type.String()),
          }),
          { description: "2 to 4 options. An implicit 'Other' free-text option is always available." },
        ),
        multi: Type.Optional(
          Type.Boolean({ description: "Allow multiple selections for this question." }),
        ),
        recommended: Type.Optional(
          Type.Integer({ description: "Index of the recommended option (0-based)." }),
        ),
      }),
      { description: "1 to 4 questions to present as a wizard." },
    ),
  });

  const description =
    "Ask the user (on their phone) one or more multiple-choice questions and wait for the answers. Use when you need a decision the user must make. 1–4 questions per call; each question has 2–4 options.";

  async function execute(
    _toolCallId: string,
    params: { questions: unknown[] },
  ) {
    const resp = await uicall({
      kind: "askUserQuestion",
      questions: params.questions as never,
    });
    if (resp.kind !== "askUserQuestion") {
      return {
        content: [{ type: "text" as const, text: "(error: wrong response kind)" }],
        details: resp,
      };
    }
    const lines = resp.answers.map((a, i) => {
      const q = (params.questions[i] as { question?: string })?.question ?? `Q${i + 1}`;
      return `Q: ${q}\nA: ${a}`;
    });
    return {
      content: [{ type: "text" as const, text: lines.join("\n\n") }],
      details: resp,
    };
  }

  // pino's canonical ask, routed to the phone via the loopback bridge. We
  // register both casings so the model reaches it whichever it emits. The
  // TUI-only `@mammothb/pi-ask` (which uses ui.custom and crashes headless) is
  // filtered out at spawn (PI_CODING_AGENT_DIR, see server/src/pi-agent-dir.ts),
  // so there is no tool-name conflict. Generic ctx.ui.select/confirm/input from
  // other extensions are transported by the PiAdapter interceptor instead.
  for (const name of ["AskUserQuestion", "askUserQuestion"]) {
    pi.registerTool({
      name,
      label: "Ask the user",
      description,
      parameters: questionsParam,
      execute,
    });
  }
}
