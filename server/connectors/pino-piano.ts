/**
 * pino-piano — connector skeleton for the "piano" agent (Milan's pi-wrapper).
 *
 * Drop-in TEMPLATE for adding a new agent to pino. The working example
 * lives at `pino-pi.ts`.
 *
 * What this file does:
 *   1. Translates piano's native tool/extension calls into the canonical
 *      UICall envelope (see ../src/uicall.ts).
 *   2. POSTs to the loopback bridge at PINO_BRIDGE_URL with
 *      PINO_BRIDGE_TOKEN. The bridge fans the request to subscribed phones
 *      via srv.request and resolves with the user's answer.
 *   3. Returns the user's answer back to piano in whatever shape it
 *      expects (here: a text content block).
 *
 * If your agent is also pi-based (uses ExtensionAPI), this skeleton works
 * as-is — just rename and register your tools. If it's a different runtime
 * (Claude SDK, codex CLI, custom), adapt the registration; the HTTP bridge
 * contract is identical.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import type { UICall, UIResponse } from "../src/uicall.js";

const BRIDGE_URL = process.env.PINO_BRIDGE_URL;
const BRIDGE_TOKEN = process.env.PINO_BRIDGE_TOKEN;
const SESSION_ID = process.env.PINO_SESSION_ID;

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
    throw new Error(`pino-piano: bridge returned ${res.status}: ${text}`);
  }
  return (await res.json()) as UIResponse;
}

export default function (api: ExtensionAPI) {
  if (!BRIDGE_URL || !BRIDGE_TOKEN) return; // not running under pino

  // -------------------------------------------------------------------------
  // Example 1: a piano-specific tool that needs a destructive confirmation.
  //
  // The tool's native parameters (title, message, action) are translated
  // into the canonical `confirmAction` UICall variant. The app already
  // knows how to render this kind, so no Flutter changes are needed.
  // -------------------------------------------------------------------------
  api.registerTool({
    name: "piano_confirm",
    label: "Confirm with the user",
    description: "Block until the user approves or denies an action.",
    parameters: Type.Object({
      title: Type.String({ description: "Short title shown in the dialog." }),
      message: Type.String({ description: "Explanation of what will happen." }),
      action: Type.String({
        description: "Name of the action (e.g. 'bash', 'file_edit').",
      }),
      preview: Type.Optional(Type.String()),
    }),
    async execute(_toolCallId, params) {
      const resp = await uicall({
        kind: "confirmAction",
        title: params.title,
        message: params.message,
        action: params.action,
        preview: params.preview,
      });
      const approved = resp.kind === "confirmAction" && resp.approved;
      return {
        content: [{ type: "text", text: approved ? "approved" : "denied" }],
        details: resp,
      };
    },
  });

  // -------------------------------------------------------------------------
  // Add more registerTool({...}) blocks here. Each one is a tiny mapping
  // from piano's native tool params → one of the UICall variants in
  // ../src/uicall.ts.
  // -------------------------------------------------------------------------
}
