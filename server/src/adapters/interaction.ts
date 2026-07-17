/**
 * interaction — the ONE elicitation/permission→UICall policy shared by the
 * subprocess adapters. acp.ts and codex.ts both encoded the same
 * "url → confirm / single-field → input / multi-field → decline" policy,
 * differing only in the transport response shape they wrapped it in (and they
 * had already started to drift). This module owns the policy; each adapter only
 * formats the normalized {@link ElicitationResult} into its wire shape.
 */

import type { AskUser } from "../uicall.js";

/** Minimal shape of the elicitation request both transports carry. */
export interface ElicitationParams {
  mode?: string;
  message?: unknown;
  url?: unknown;
  requestedSchema?: { properties?: Record<string, unknown> } | null;
}

/** Normalized elicitation outcome; adapters map this to their wire response. */
export interface ElicitationResult {
  action: "accept" | "decline" | "cancel";
  /** Present only on `accept` for a single-field form. */
  content?: Record<string, string | number | boolean>;
}

/** A confirmAction to present on the phone. */
export interface ConfirmSpec {
  sessionId: string;
  title: string;
  message: string;
  action: string;
  preview?: string;
}

/**
 * Present a confirmAction and resolve to a plain approve/deny boolean. Returns
 * `false` (fail-safe deny) when no phone is attached or the user cancels.
 */
export async function confirmViaUser(
  askUser: AskUser | undefined,
  spec: ConfirmSpec,
): Promise<boolean> {
  if (!askUser) return false;
  const resp = await askUser({
    kind: "confirmAction",
    sessionId: spec.sessionId,
    title: spec.title,
    message: spec.message,
    action: spec.action,
    ...(spec.preview ? { preview: spec.preview } : {}),
  });
  return resp.kind === "confirmAction" && !(resp as { cancelled?: boolean }).cancelled && resp.approved === true;
}

/**
 * Apply the shared elicitation policy:
 *   - `url` mode      → confirmAction (show the link); accept/decline/cancel
 *   - single-field    → input; accept with the (type-coerced) value
 *   - multi-field / 0 → decline (full form UI is out of scope)
 * Fail-safe declines when no phone is attached.
 */
export async function mapElicitation(
  params: ElicitationParams,
  askUser: AskUser | undefined,
  sessionId: string,
): Promise<ElicitationResult> {
  if (!askUser) return { action: "decline" };

  const message = typeof params.message === "string" ? params.message : "The agent needs input.";

  if (params.mode === "url") {
    const resp = await askUser({
      kind: "confirmAction",
      sessionId,
      title: "Open link?",
      message,
      action: "open-url",
      ...(typeof params.url === "string" ? { preview: params.url } : {}),
    });
    if (resp.kind === "confirmAction" && !(resp as { cancelled?: boolean }).cancelled) {
      return { action: resp.approved ? "accept" : "decline" };
    }
    return { action: "cancel" };
  }

  // form mode: only single-field forms map to the input UICall.
  const props = (params.requestedSchema?.properties ?? {}) as Record<string, ElicitationField>;
  const names = Object.keys(props);
  if (names.length !== 1) return { action: "decline" };

  const name = names[0]!;
  const field = props[name] ?? {};
  const resp = await askUser({
    kind: "input",
    sessionId,
    title: message,
    placeholder: typeof field.description === "string" ? field.description : field.title,
    prefill: field.default != null ? String(field.default) : undefined,
    multiline: false,
  });
  if (resp.kind === "input" && !resp.cancelled && typeof resp.value === "string") {
    const parsed = parseFieldValue(resp.value, field.type);
    // A value that doesn't cleanly satisfy the declared schema type is
    // declined rather than silently coerced (blank≠0, "abc"≠string number,
    // 1.5≠integer, arbitrary text≠false).
    if (!parsed.ok) return { action: "decline" };
    return { action: "accept", content: { [name]: parsed.value } };
  }
  return { action: "decline" };
}

/** One elicitation form field's declared schema (only what we consume). */
interface ElicitationField {
  type?: unknown;
  description?: unknown;
  title?: string;
  default?: unknown;
}

/**
 * Validate a free-text input value against the field's declared JSON-schema
 * type. Returns `{ ok:false }` for a value that doesn't cleanly satisfy the
 * type so the caller can decline rather than silently coerce:
 *   - number  → must parse to a finite number (blank/"abc" reject)
 *   - integer → must parse to a finite integer (1.5 rejects)
 *   - boolean → must be an exact truthy/falsy token (arbitrary text rejects)
 *   - anything else (string / untyped) → accepted verbatim
 */
export function parseFieldValue(
  value: string,
  type: unknown,
): { ok: true; value: string | number | boolean } | { ok: false } {
  if (type === "number" || type === "integer") {
    const trimmed = value.trim();
    if (trimmed === "") return { ok: false };
    const n = Number(trimmed);
    if (!Number.isFinite(n)) return { ok: false };
    if (type === "integer" && !Number.isInteger(n)) return { ok: false };
    return { ok: true, value: n };
  }
  if (type === "boolean") {
    const t = value.trim().toLowerCase();
    if (/^(true|yes|1|y)$/.test(t)) return { ok: true, value: true };
    if (/^(false|no|0|n)$/.test(t)) return { ok: true, value: false };
    return { ok: false };
  }
  return { ok: true, value };
}
