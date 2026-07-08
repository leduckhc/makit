/**
 * APNs adapter.
 *
 * Two parts:
 *   - `apnsDisposition` — a PURE classifier mapping APNs HTTP feedback to a
 *     {@link PushResult}. Unit-tested (see `wake_coordinator.test.ts`, A7).
 *   - `ApnsPushSender` — the REAL HTTP/2 + ES256-JWT adapter. This is
 *     platform/network I/O (see SPEC-07 W2) and is NOT unit-tested here; it is
 *     exercised only by the on-device checklist. It is genuine (not stubbed):
 *     `enabled === true` and `wake()` signs a provider JWT and POSTs to Apple.
 */

import { readFileSync } from "node:fs";
import { connect as http2Connect } from "node:http2";
import { createSign, KeyObject, createPrivateKey } from "node:crypto";

import { log } from "../log.js";
import type { ApnsPayload } from "./payload.js";
import type { PushResult, PushSender, PushTarget } from "./sender.js";

/**
 * Pure: classify an APNs response into the {@link PushResult} the coordinator
 * acts on. A `dead` disposition (unregistered / bad token) means the stored
 * token should be cleared; `error` is transient and keeps the token.
 */
export function apnsDisposition(status: number, reason?: string): PushResult {
  if (status === 200) return "ok";
  // 410 Unregistered and 400 BadDeviceToken are permanent → the token is dead.
  if (status === 410) return "dead";
  if (status === 400 && reason === "BadDeviceToken") return "dead";
  if (reason === "Unregistered" || reason === "BadDeviceToken") return "dead";
  // Everything else (429/500/503/…) is transient — keep the token, retry later.
  return "error";
}

/** Resolved APNs provider config (see `~/.pino/push.json`). */
export interface ApnsConfig {
  keyPath: string;
  keyId: string;
  teamId: string;
  bundleId: string;
  /** "sandbox" | "production" — selects the APNs host. */
  env: "sandbox" | "production";
}

const APNS_HOST_PROD = "https://api.push.apple.com";
const APNS_HOST_SANDBOX = "https://api.sandbox.push.apple.com";
/** APNs provider tokens are valid for 60 min; refresh well inside that window. */
const JWT_TTL_MS = 50 * 60 * 1000;
/** Abort a wake request that stalls this long so the session can't leak. */
const APNS_REQUEST_TIMEOUT_MS = 10_000;

/**
 * Real APNs sender. NOT unit-tested (network + crypto I/O) — verified by the
 * SPEC-07 on-device checklist. `enabled === true`, so `WakeCoordinator` treats
 * a successful `devicesToWake` as a real dispatch and keeps requests pending.
 */
export class ApnsPushSender implements PushSender {
  readonly enabled = true;

  private readonly key: KeyObject;
  private jwt: { token: string; issuedAt: number } | null = null;

  constructor(private readonly config: ApnsConfig) {
    this.key = createPrivateKey(readFileSync(config.keyPath, "utf8"));
  }

  private providerToken(): string {
    const now = Date.now();
    if (this.jwt && now - this.jwt.issuedAt < JWT_TTL_MS) return this.jwt.token;
    const header = { alg: "ES256", kid: this.config.keyId };
    const claims = { iss: this.config.teamId, iat: Math.floor(now / 1000) };
    const b64 = (o: unknown) =>
      Buffer.from(JSON.stringify(o)).toString("base64url");
    const signingInput = `${b64(header)}.${b64(claims)}`;
    const signature = createSign("SHA256")
      .update(signingInput)
      .sign({ key: this.key, dsaEncoding: "ieee-p1363" })
      .toString("base64url");
    const token = `${signingInput}.${signature}`;
    this.jwt = { token, issuedAt: now };
    return token;
  }

  async wake(target: PushTarget, payload: ApnsPayload): Promise<PushResult> {
    const host = this.config.env === "production" ? APNS_HOST_PROD : APNS_HOST_SANDBOX;
    return new Promise<PushResult>((resolve) => {
      let settled = false;
      let session: ReturnType<typeof http2Connect> | null = null;
      const done = (r: PushResult) => {
        if (settled) return;
        settled = true;
        // Always tear the session down so a stalled/half-open APNs connection
        // can't leak the underlying socket, regardless of which path we hit.
        try {
          session?.close();
          session?.destroy();
        } catch {
          /* best-effort cleanup */
        }
        resolve(r);
      };
      try {
        session = http2Connect(host);
        session.on("error", (e) => {
          log.warn(`[pino] push: APNs connect error: ${e.message}`);
          done("error");
        });
        const req = session.request({
          ":method": "POST",
          ":path": `/3/device/${target.token}`,
          authorization: `bearer ${this.providerToken()}`,
          "apns-topic": this.config.bundleId,
          "apns-push-type": "alert",
          "apns-priority": "10",
        });
        // Abort a request that stalls (e.g. APNs edge unreachable over the
        // tailnet) so we never hang holding the session open indefinitely.
        req.setTimeout(APNS_REQUEST_TIMEOUT_MS, () => {
          log.warn("[pino] push: APNs request timed out");
          try {
            req.close();
          } catch {
            /* best-effort */
          }
          done("error");
        });
        let status = 0;
        let bodyText = "";
        req.on("response", (headers) => {
          status = Number(headers[":status"]) || 0;
        });
        req.setEncoding("utf8");
        req.on("data", (chunk) => (bodyText += chunk));
        req.on("end", () => {
          let reason: string | undefined;
          try {
            reason = bodyText ? (JSON.parse(bodyText).reason as string) : undefined;
          } catch {
            /* non-JSON body — leave reason undefined */
          }
          done(apnsDisposition(status, reason));
        });
        req.on("error", (e) => {
          log.warn(`[pino] push: APNs request error: ${e.message}`);
          done("error");
        });
        req.end(JSON.stringify(payload));
      } catch (e) {
        log.warn(`[pino] push: APNs send threw: ${(e as Error).message}`);
        done("error");
      }
    });
  }
}
