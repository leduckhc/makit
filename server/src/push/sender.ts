/**
 * PushSender — pluggable seam for delivering a content-free wake to a device.
 *
 * `NoopPushSender` (default in dev/test/when unconfigured) reports
 * `enabled === false` so the {@link WakeCoordinator} never dispatches and
 * `askDevice` keeps today's reject-immediately semantics. `ApnsPushSender`
 * (see `apns.ts`) is the real HTTP/2 adapter, gated behind `~/.pino/push.json`
 * and NOT unit-tested (platform I/O).
 */

import type { ApnsPayload } from "./payload.js";

/** A device we can push to. `platform` routes apns vs. fcm (future). */
export interface PushTarget {
  deviceId: string;
  token: string;
  /** "apns" | "fcm" — the routing seam for future FCM support. */
  platform: string;
  /** APNs environment for this token: "sandbox" | "production". */
  env?: string;
}

/** Outcome of a wake attempt. `dead` → the token should be cleared. */
export type PushResult = "ok" | "dead" | "error";

export interface PushSender {
  /** True only for a real, configured sender. Gates the keep-pending decision. */
  readonly enabled: boolean;
  /** Best-effort deliver a wake. Never throws; classifies its own failure. */
  wake(target: PushTarget, payload: ApnsPayload): Promise<PushResult>;
}

/**
 * The default sender: does nothing and reports `enabled === false`. With Noop
 * installed, `WakeCoordinator.wake` short-circuits to `false`, so a stale
 * stored token can never make `askDevice` hang for the full timeout.
 */
export class NoopPushSender implements PushSender {
  readonly enabled = false;

  async wake(): Promise<PushResult> {
    return "ok";
  }
}
