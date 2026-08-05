/**
 * Pure logic for the pi usage reporter (SPEC-37), kept free of I/O and of pi's
 * API so it can be unit-tested directly. `index.ts` owns the pi hook and the
 * `fetch` call.
 *
 * Env contract, injected by the makit server for every spawned session
 * (`manager.ts` `startOpts`):
 *
 * - `MAKIT_BRIDGE_URL`   — loopback bridge base url
 * - `MAKIT_BRIDGE_TOKEN` — bearer for that bridge
 * - `MAKIT_SESSION_ID`   — the makit session this pi process belongs to
 *
 * All three are required: without them this pi process was not launched by makit
 * (a plain terminal session), and reporting usage would have nowhere to go.
 */

export interface BridgeTarget {
  url: string;
  token: string;
  sessionId: string;
}

export function resolveBridge(env: Record<string, string | undefined>): BridgeTarget | undefined {
  const url = env.MAKIT_BRIDGE_URL;
  const token = env.MAKIT_BRIDGE_TOKEN;
  const sessionId = env.MAKIT_SESSION_ID;
  if (!url || !token || !sessionId) return undefined;
  return { url, token, sessionId };
}

/** What `ctx.getContextUsage()` returns, per pi's docs (extensions.md). */
export interface PiContextUsage {
  tokens?: number | null;
  contextWindow?: number | null;
  percent?: number | null;
}

/** The `usage.cost` shape on a pi assistant message. */
export interface PiCost {
  total?: number | null;
}

/** The `usage` payload of makit's `POST /usage`. */
export interface UsagePayload {
  contextTokens?: number;
  contextWindow?: number;
  cost?: { amount: number; currency: string };
}

function finite(v: unknown): number | undefined {
  return typeof v === "number" && Number.isFinite(v) ? v : undefined;
}

/**
 * Build the wire payload from pi's readings.
 *
 * Fields are OMITTED, never zeroed, when pi has no reading: `getContextUsage()`
 * returns null tokens right after compaction until a fresh assistant response
 * lands, and a 0 there would render as an empty context bar rather than as
 * "not measured yet".
 *
 * Returns `undefined` when nothing at all is known, so the caller can skip the
 * request instead of posting a snapshot that would be rejected as empty.
 */
export function buildUsage(
  usage: PiContextUsage | undefined | null,
  cost?: PiCost | null,
  currency = "USD",
): UsagePayload | undefined {
  const contextTokens = finite(usage?.tokens);
  const contextWindow = finite(usage?.contextWindow);
  const amount = finite(cost?.total);
  const payload: UsagePayload = {
    ...(contextTokens !== undefined ? { contextTokens } : {}),
    ...(contextWindow !== undefined ? { contextWindow } : {}),
    ...(amount !== undefined ? { cost: { amount, currency } } : {}),
  };
  return Object.keys(payload).length ? payload : undefined;
}

/**
 * True when `next` is worth sending given the last payload sent.
 *
 * pi fires `message_end` for every assistant message, including ones that only
 * carry a tool call, so consecutive identical readings are common. Suppressing
 * them keeps one HTTP round trip per real change rather than per message.
 */
export function isWorthSending(last: UsagePayload | undefined, next: UsagePayload): boolean {
  if (!last) return true;
  return (
    last.contextTokens !== next.contextTokens ||
    last.contextWindow !== next.contextWindow ||
    last.cost?.amount !== next.cost?.amount
  );
}
