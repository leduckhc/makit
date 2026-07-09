/**
 * WakeCoordinator — decides which devices to wake and dispatches a
 * content-free push. Behind `ReverseRpc.onUndeliverable`, it returns the
 * synchronous keep-pending gate:
 *
 *   - `false` when the sender is disabled (Noop) OR nothing needs waking →
 *     `askDevice` rejects immediately (matches Slice-1 today).
 *   - `true`  when a real, enabled sender has ≥1 not-connected token-bearing
 *     target → `askDevice` keeps the request pending so the woken device can
 *     answer.
 *
 * The boolean is the keep-pending gate; APNs accept/reject is async and never
 * blocks it. A `'dead'` disposition (410/BadDeviceToken) best-effort clears the
 * stored token so it can't trigger wake-then-hang on the next `askDevice`.
 */

import type { Envelope } from "../protocol.js";
import type { PushSender, PushTarget } from "./sender.js";
import type { buildWakePayload as BuildWakePayload } from "./payload.js";

/** The device fields the coordinator reads. */
export interface PairedDeviceView {
  id: string;
  pushToken?: string;
  pushPlatform?: string;
  pushEnv?: string;
}

/** The registry slice the coordinator depends on. */
export interface WakeRegistry {
  list(): PairedDeviceView[];
  clearPushToken(deviceId: string): void;
}

/** Pure: which paired devices have a token and no live socket. */
export function devicesToWake({
  pairedDevices,
  connectedDeviceIds,
}: {
  pairedDevices: PairedDeviceView[];
  connectedDeviceIds: Set<string>;
}): PushTarget[] {
  const targets: PushTarget[] = [];
  for (const d of pairedDevices) {
    if (!d.pushToken) continue;
    if (connectedDeviceIds.has(d.id)) continue;
    targets.push({
      deviceId: d.id,
      token: d.pushToken,
      platform: d.pushPlatform ?? "apns",
      env: d.pushEnv,
    });
  }
  return targets;
}

export interface WakeCoordinatorDeps {
  registry: WakeRegistry;
  connectedDeviceIds: () => Set<string>;
  sender: PushSender;
  buildWakePayload: typeof BuildWakePayload;
}

export class WakeCoordinator {
  constructor(private readonly deps: WakeCoordinatorDeps) {}

  /**
   * Attempt to wake every not-connected token-bearing device. Returns the
   * synchronous keep-pending gate (see file header).
   */
  wake(
    _envelope: Envelope | Record<string, unknown>,
    { pendingCount }: { sessionId?: string; pendingCount: number },
  ): boolean {
    if (!this.deps.sender.enabled) return false;
    const targets = devicesToWake({
      pairedDevices: this.deps.registry.list(),
      connectedDeviceIds: this.deps.connectedDeviceIds(),
    });
    if (targets.length === 0) return false;

    const payload = this.deps.buildWakePayload({ pendingCount });
    for (const target of targets) {
      // Fire-and-forget: the boolean gate must not await network I/O.
      void this.deps.sender
        .wake(target, payload)
        .then((result) => {
          if (result === "dead") this.deps.registry.clearPushToken(target.deviceId);
        })
        .catch(() => {
          /* best-effort: a failed send never surfaces into askDevice */
        });
    }
    return true;
  }
}
