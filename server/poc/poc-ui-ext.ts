/**
 * POC extension: proves makit can intercept pi's ctx.ui.* calls over rpc.
 *
 * Registers `poc_ask`, which exercises the three interceptable UI methods:
 *   ctx.ui.select  → single choice
 *   ctx.ui.confirm → yes/no
 *   ctx.ui.input   → free text
 *
 * In makit's rpc mode each call emits an `extension_ui_request` on stdout and
 * blocks until the host writes an `extension_ui_response`. The POC harness
 * (poc-interceptor.mjs) plays the role of makit/PiAdapter + phone.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "poc_ask",
    label: "POC ask",
    description:
      "POC tool. Ask the user a color via select, a confirm, and a free-text name via input. Call this immediately when asked.",
    parameters: { type: "object", properties: {} } as never,
    async execute(_toolCallId, _params, _signal, _onUpdate, ctx: any) {
      const color = await ctx.ui.select("Pick a color", ["Red", "Green", "Blue"]);
      const sure = await ctx.ui.confirm("Confirm", `You picked ${color}. Proceed?`);
      const name = await ctx.ui.input("Your name", "type here");
      return {
        content: [
          { type: "text", text: `color=${color} sure=${sure} name=${name}` },
        ],
      };
    },
  });
}
