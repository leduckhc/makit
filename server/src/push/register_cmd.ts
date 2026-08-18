/**
 * `push.register` command handler (SPEC-background-wake-notifications A4).
 *
 * Extracted from `server.ts` so the pure handler logic is unit-testable
 * against a `CommandRouter` + fake `WsClient` + fake registry, with no live
 * socket. `server.ts` wires it via `registerPushCommands(router, registry)`.
 *
 * The phone sends `cmd {kind:'push.register', token, platform, env?}` after a
 * successful (re)connect; we persist the token per-device so the
 * `WakeCoordinator` can wake it later.
 */

import { WireErrorCode } from "../protocol/codec.js";
import type { CommandRouter } from "../ws/command_router.js";

/** The registry slice the handler depends on. */
export interface PushTokenRegistry {
  setPushToken(
    deviceId: string,
    info: { token: string; platform: string; env?: string },
  ): void;
}

export function registerPushCommands(
  router: CommandRouter,
  registry: PushTokenRegistry,
): void {
  router.register("push.register", (ctx) => {
    const deviceId = ctx.client.deviceId;
    if (!ctx.client.authed || !deviceId) {
      ctx.err(WireErrorCode.Unauthorized, "push.register requires an authed device");
      return;
    }
    const token = typeof ctx.env.token === "string" ? ctx.env.token : "";
    if (!token) {
      ctx.err(WireErrorCode.BadRequest, "push.register requires a string `token`");
      return;
    }
    const platform = typeof ctx.env.platform === "string" ? ctx.env.platform : "apns";
    const env = typeof ctx.env.env === "string" ? ctx.env.env : undefined;
    registry.setPushToken(deviceId, { token, platform, env });
    ctx.ack();
  });
}
