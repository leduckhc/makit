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
 *   1. Copy this file.
 *   2. Replace `registerTool({...})` calls with the equivalent in your
 *      agent's extension API.
 *   3. In each tool's execute(), translate the agent-native params into
 *      one of the canonical UICall variants from `../src/uicall.ts`.
 *   4. Drop the file in `server/connectors/` — pino auto-loads everything
 *      there into the spawned agent.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import type { AskMultipleChoice, UICallResponse } from "../src/uicall.js";

const BRIDGE_URL = process.env.PINO_BRIDGE_URL;
const BRIDGE_TOKEN = process.env.PINO_BRIDGE_TOKEN;
const SESSION_ID = process.env.PINO_SESSION_ID;

/** Post a UICall to the loopback bridge, await the user's response. */
async function uicall(call: AskMultipleChoice): Promise<UICallResponse> {
  const res = await fetch(`${BRIDGE_URL}/ask`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${BRIDGE_TOKEN}`,
    },
    body: JSON.stringify({
      sessionId: SESSION_ID,
      timeoutMs: 10 * 60 * 1000,
      ...call,
    }),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`pino-pi: bridge returned ${res.status}: ${text}`);
  }
  return (await res.json()) as UICallResponse;
}

export default function (pi: ExtensionAPI) {
  if (!BRIDGE_URL || !BRIDGE_TOKEN) return; // not running under pino

  pi.registerTool({
    name: "askUserQuestion",
    label: "Ask the user",
    description:
      "Ask the user (on their phone) one or more multiple-choice questions and wait for the answers. Use when you need a decision the user must make. 1–4 questions per call; each question has 2–4 options.",
    parameters: Type.Object({
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
    }),
    async execute(_toolCallId, params) {
      // pi's native schema already matches the canonical AskMultipleChoice
      // questions shape — just forward.
      const response = await uicall({
        kind: "askMultipleChoice",
        questions: params.questions,
      });
      if (response.ok === false) {
        return {
          content: [
            {
              type: "text",
              text: response.cancelled
                ? "(user cancelled)"
                : `(error: ${response.error ?? "unknown"})`,
            },
          ],
          details: { cancelled: !!response.cancelled },
        };
      }
      const answers = Array.isArray(response.answers) ? response.answers : [];
      const lines = answers.map((a, i) => {
        const q = (params.questions[i] as { question: string } | undefined)?.question ?? `Q${i + 1}`;
        const text = Array.isArray(a) ? (a as string[]).join(", ") : String(a);
        return `Q: ${q}\nA: ${text}`;
      });
      return {
        content: [{ type: "text", text: lines.join("\n\n") }],
        details: response,
      };
    },
  });
}
