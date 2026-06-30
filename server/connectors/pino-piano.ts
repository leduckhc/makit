/**
 * pino-piano — connector skeleton for the "piano" agent (Milan's pi-wrapper).
 *
 * This is a TEMPLATE you fork to wire a custom agent into pino. The pi
 * connector at `pino-pi.ts` is the working example.
 *
 * What goes here:
 *   1. Translate your agent's native tool/extension calls into the
 *      canonical UICall envelope (see ../src/uicall.ts).
 *   2. POST to the loopback bridge with PINO_BRIDGE_URL / PINO_BRIDGE_TOKEN.
 *   3. Return the user's answer back to your agent in whatever shape it
 *      expects.
 *
 * If your agent is also pi-based (uses ExtensionAPI), this file structure
 * works as-is — just rename, register your tools, and you're done.
 *
 * If your agent is a different runtime (Claude SDK, codex CLI, custom),
 * adapt the registration to that runtime's extension surface. The HTTP
 * bridge contract is the same regardless of language.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import type { UICall, UICallResponse } from "../src/uicall.js";

const BRIDGE_URL = process.env.PINO_BRIDGE_URL;
const BRIDGE_TOKEN = process.env.PINO_BRIDGE_TOKEN;
const SESSION_ID = process.env.PINO_SESSION_ID;

/** Shared helper: send any canonical UICall to the bridge, await answer. */
async function uicall(call: UICall, timeoutMs = 10 * 60 * 1000): Promise<UICallResponse> {
  const res = await fetch(`${BRIDGE_URL}/ask`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${BRIDGE_TOKEN}`,
    },
    body: JSON.stringify({ sessionId: SESSION_ID, timeoutMs, ...call }),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`pino-piano: bridge returned ${res.status}: ${text}`);
  }
  return (await res.json()) as UICallResponse;
}

export default function (api: ExtensionAPI) {
  if (!BRIDGE_URL || !BRIDGE_TOKEN) return; // not running under pino

  // -------------------------------------------------------------------------
  // Example 1: a custom tool that needs free-text input.
  // Replace the name/parameters with your agent's native tool. The body of
  // execute() shows how to translate to/from the canonical UICall schema.
  // -------------------------------------------------------------------------
  api.registerTool({
    name: "piano_ask_text",
    label: "Ask piano user (free-text)",
    description: "Ask the user a free-text question via pino's phone UI.",
    parameters: Type.Object({
      prompt: Type.String({ description: "Question to display." }),
      placeholder: Type.Optional(Type.String()),
      multiline: Type.Optional(Type.Boolean()),
    }),
    async execute(_toolCallId, params) {
      const resp = await uicall({
        kind: "askFreeText",
        prompt: params.prompt,
        placeholder: params.placeholder,
        multiline: params.multiline,
      });
      if (resp.ok === false) {
        return {
          content: [{ type: "text", text: resp.cancelled ? "(cancelled)" : `(error: ${resp.error})` }],
          details: { cancelled: !!resp.cancelled },
        };
      }
      return {
        content: [{ type: "text", text: String(resp.text ?? "") }],
        details: resp,
      };
    },
  });

  // -------------------------------------------------------------------------
  // Example 2: a destructive action that needs explicit user confirmation.
  // Maps your agent's "are you sure?" prompt into ConfirmDestructive UICall.
  // -------------------------------------------------------------------------
  api.registerTool({
    name: "piano_confirm_destructive",
    label: "Confirm destructive action",
    description: "Block an irreversible operation until the user confirms.",
    parameters: Type.Object({
      title: Type.String(),
      message: Type.String(),
    }),
    async execute(_toolCallId, params) {
      const resp = await uicall({
        kind: "confirmDestructive",
        title: params.title,
        message: params.message,
      });
      const confirmed = resp.ok === true && resp.confirmed === true;
      return {
        content: [{ type: "text", text: confirmed ? "confirmed" : "cancelled" }],
        details: resp,
      };
    },
  });

  // Add more pi.registerTool({...}) blocks as needed. Each one is a small
  // mapping from your agent's native tool params → one of the UICall
  // variants in ../src/uicall.ts.
}
