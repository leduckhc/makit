/**
 * pino-pi — pi extension that exposes `askUserQuestion` as a real pi tool.
 *
 * Loaded into pi via `pi --mode rpc -e <this-file>`. Reads `PINO_BRIDGE_URL`
 * and `PINO_BRIDGE_TOKEN` from env, set by pino's PiAdapter, plus
 * `PINO_SESSION_ID` so the bridge can route the question to the right
 * subscribed clients.
 *
 * Schema mirrors the Anthropic-standard `askUserQuestion` (1–4 questions
 * in one call, each with 2–4 options). The phone renders a wizard and
 * returns one answer per question.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const BRIDGE_URL = process.env.PINO_BRIDGE_URL;
const BRIDGE_TOKEN = process.env.PINO_BRIDGE_TOKEN;
const SESSION_ID = process.env.PINO_SESSION_ID;

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
      const res = await fetch(`${BRIDGE_URL}/ask`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${BRIDGE_TOKEN}`,
        },
        body: JSON.stringify({
          sessionId: SESSION_ID,
          kind: "askUserQuestion",
          questions: params.questions,
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
          content: [
            {
              type: "text",
              text: body.cancelled
                ? "(user cancelled)"
                : `(error: ${body.error ?? "unknown"})`,
            },
          ],
          details: { cancelled: !!body.cancelled },
        };
      }
      const answers = Array.isArray(body.answers) ? body.answers : [];
      // Format as "Q: ... → A: ..." pairs so pi sees a readable result.
      const lines = answers.map((a, i) => {
        const q = (params.questions[i] as { question: string } | undefined)?.question ?? `Q${i + 1}`;
        const text = Array.isArray(a) ? a.join(", ") : String(a);
        return `Q: ${q}\nA: ${text}`;
      });
      return {
        content: [{ type: "text", text: lines.join("\n\n") }],
        details: body,
      };
    },
  });
}
