/**
 * pino-pi — pi extension that exposes `askUserQuestion` as a real pi tool.
 *
 * Loaded into pi via `pi --mode rpc -e <this-file>`. Reads `PINO_BRIDGE_URL`
 * and `PINO_BRIDGE_TOKEN` from env, set by pino's PiAdapter, plus
 * `PINO_SESSION_ID` so the bridge can route the question to the right
 * subscribed clients.
 *
 * When pi calls the tool, we POST to the bridge and block until the user on
 * the phone picks an option. The answer is returned to pi as a tool result,
 * so pi sees it as if it had asked locally.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const BRIDGE_URL = process.env.PINO_BRIDGE_URL;
const BRIDGE_TOKEN = process.env.PINO_BRIDGE_TOKEN;
const SESSION_ID = process.env.PINO_SESSION_ID;

export default function (pi: ExtensionAPI) {
  if (!BRIDGE_URL || !BRIDGE_TOKEN) {
    // Loaded without a pino bridge — nothing useful to do, stay silent.
    return;
  }

  pi.registerTool({
    name: "askUserQuestion",
    label: "Ask the user",
    description:
      "Ask the user (on their phone) a multiple-choice question and wait for the answer. Use when you need a decision the user must make.",
    parameters: Type.Object({
      header: Type.Optional(
        Type.String({ description: "Short label (max ~12 chars) shown in the dialog header." }),
      ),
      question: Type.String({ description: "The question to display." }),
      options: Type.Array(
        Type.Object({
          label: Type.String({ description: "Option label (1-5 words)." }),
          description: Type.Optional(Type.String()),
        }),
        { description: "2 to 4 options. An implicit 'Other' free-text option is always available." },
      ),
      multi: Type.Optional(Type.Boolean({ description: "Allow multiple selections." })),
      recommended: Type.Optional(Type.Integer({ description: "Index of the recommended option (0-based)." })),
    }),
    async execute(_toolCallId, params) {
      const res = await fetch(`${BRIDGE_URL}/ask`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${BRIDGE_TOKEN}`,
        },
        body: JSON.stringify({
          sessionId: SESSION_ID,
          kind: "askUserQuestion",
          ...params,
          timeoutMs: 10 * 60 * 1000, // 10 min — give the user time to look at their phone
        }),
      });
      if (!res.ok) {
        const text = await res.text().catch(() => "");
        throw new Error(`pino-pi: bridge returned ${res.status}: ${text}`);
      }
      const body = (await res.json()) as Record<string, unknown>;
      if (body.ok === false) {
        return {
          content: [{ type: "text", text: body.cancelled ? "(user cancelled)" : `(error: ${body.error ?? "unknown"})` }],
          details: { cancelled: !!body.cancelled },
        };
      }
      const answer = Array.isArray(body.answer)
        ? (body.answer as string[]).join(", ")
        : (body.answer as string) ?? JSON.stringify(body);
      return {
        content: [{ type: "text", text: answer }],
        details: body,
      };
    },
  });
}
