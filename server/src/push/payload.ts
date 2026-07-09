/**
 * Content-free APNs wake payload.
 *
 * The privacy invariant is the SIGNATURE: `buildWakePayload` accepts only an
 * integer, so no `Envelope`, session id, request body, or message text is ever
 * in scope — no session data *can* leak into the payload by construction. The
 * accompanying test (`push_payload.test.ts`) walks the payload recursively and
 * allowlists the key set at every level to catch any future dynamic-text field.
 */

/** The alert half of an APNs `aps` dictionary. */
export interface ApnsAlert {
  title: string;
  body: string;
}

/** The `aps` dictionary Apple reads to buzz + wake the device. */
export interface ApnsAps {
  alert: ApnsAlert;
  sound: string;
  badge: number;
  /** 1 → wake the app in the background (content-available). */
  "content-available": number;
}

/** A full APNs push payload (content-free). */
export interface ApnsPayload {
  aps: ApnsAps;
}

/** Generic, session-free alert title. */
export const WAKE_ALERT_TITLE = "makit";
/** Generic, session-free alert body — never varies with request content. */
export const WAKE_ALERT_BODY = "An agent needs you";

/**
 * Build the content-free wake payload. It is simultaneously a user-visible
 * alert (guarantees the buzz regardless of background execution) and a
 * `content-available` silent wake (lets the app opportunistically reconnect
 * and upgrade to the Slice-1 actionable notification).
 */
export function buildWakePayload({ pendingCount }: { pendingCount: number }): ApnsPayload {
  return {
    aps: {
      alert: { title: WAKE_ALERT_TITLE, body: WAKE_ALERT_BODY },
      sound: "default",
      badge: pendingCount,
      "content-available": 1,
    },
  };
}
