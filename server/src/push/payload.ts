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
  /**
   * Absent leaves the app's current badge alone; a number REPLACES it (so `0`
   * clears it). Only a payload that actually knows the pending count should send
   * one — see {@link buildPortDownPayload}.
   */
  badge?: number;
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
 * The port-down alert (SPEC-ports-forward D8).
 *
 * It carries the PORT NUMBER and nothing else — no branch, no command, no
 * session, no path. That is a deliberate line: the privacy invariant of this file
 * is that a payload cannot contain project content, and a branch name on a lock
 * screen is exactly the kind of content it protects. A port number is host
 * metadata (the same class of fact the kill audit line logs), and it is the one
 * thing the alert needs in order to be actionable.
 */
export function buildPortDownPayload({ port }: { port: number }): ApnsPayload {
  return {
    aps: {
      alert: { title: WAKE_ALERT_TITLE, body: `:${port} stopped listening` },
      sound: "default",
      // No `badge` on purpose: this alert knows nothing about pending requests,
      // and APNs treats `badge: 0` as "clear it" — which would wipe the count a
      // waiting turn had set. Absent leaves it untouched.
      "content-available": 1,
    },
  };
}

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
