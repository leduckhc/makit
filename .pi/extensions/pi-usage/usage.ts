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

/**
 * The `usage` of ONE pi assistant message (`pi-ai`'s `Usage`). Every field is a
 * per-message delta, which is why {@link addUsage} exists: makit's `totals` and
 * `cost` are cumulative for the session.
 *
 * `reasoning` is a subset of `output` (pi documents it as such) and only some
 * providers report it at all.
 */
export interface PiMessageUsage {
  input?: number | null;
  output?: number | null;
  cacheRead?: number | null;
  cacheWrite?: number | null;
  reasoning?: number | null;
  cost?: PiCost | null;
}

/**
 * One session entry, as `ctx.sessionManager.getEntries()` yields them (the
 * subset {@link sumUsage} reads). `usage` sits on the entry itself for
 * compaction/branch summaries and on the message for assistant/tool results.
 */
export interface PiSessionEntry {
  type?: string;
  usage?: PiMessageUsage | null;
  message?: { role?: string; usage?: PiMessageUsage | null } | null;
}

/**
 * Per-category session sums, in PI's categories (`input` excludes cache
 * reads/writes, exactly as pi reports it). {@link buildUsage} converts them to
 * makit's, where cached input is a subset of input.
 *
 * A key is ABSENT until pi reports a finite number for it at least once, so a
 * provider that never breaks out reasoning renders as unknown rather than as a
 * real zero (the same absent-is-not-zero rule `SessionUsageDTO` follows).
 */
export interface UsageAccumulator {
  input?: number;
  cachedInput?: number;
  cacheWrite?: number;
  output?: number;
  reasoning?: number;
  cost?: number;
}

/** The `usage` payload of makit's `POST /usage`. */
export interface UsagePayload {
  contextTokens?: number;
  contextWindow?: number;
  totals?: {
    total?: number;
    input?: number;
    cachedInput?: number;
    cacheWrite?: number;
    output?: number;
    reasoning?: number;
  };
  cost?: { amount: number; currency: string };
}

function finite(v: unknown): number | undefined {
  return typeof v === "number" && Number.isFinite(v) ? v : undefined;
}

/**
 * Sum the session's usage over its entries, reproducing what pi's own
 * `/sessions` command prints (`AgentSession.getSessionStats`): every assistant
 * message, every tool result that was billed (tool-side summarisation), and
 * every compaction/branch summary — including history that has since been
 * compacted away, because it was still billed.
 *
 * Derived rather than accumulated on purpose: an extension only sees the
 * `message_end` events of ITS process, so a **resumed** session would restart
 * from zero and a compaction's own tokens would never be counted. The entries
 * are the same source of truth `/sessions` reads, so the two agree exactly.
 *
 * Nothing here is trusted to be a number: entries come from a user-editable
 * JSONL file, and a `NaN` would propagate into the UI as `NaN%`.
 */
export function sumUsage(entries: Iterable<PiSessionEntry> | undefined | null): UsageAccumulator {
  let acc: UsageAccumulator = {};
  for (const entry of entries ?? []) {
    // Compaction and branch summaries carry their own usage on the entry.
    if (entry?.type === "branch_summary" || entry?.type === "compaction") acc = addUsage(acc, entry.usage);
    if (entry?.type !== "message") continue;
    const role = entry.message?.role;
    if (role === "assistant" || role === "toolResult") acc = addUsage(acc, entry.message?.usage);
  }
  return acc;
}

/**
 * Fold one usage reading into the running sums, returning a new accumulator.
 *
 * Exported for {@link sumUsage}'s tests; callers should prefer `sumUsage`, which
 * knows which entries are billable.
 */
export function addUsage(
  acc: UsageAccumulator,
  usage: PiMessageUsage | undefined | null,
): UsageAccumulator {
  if (!usage) return acc;
  const next = { ...acc };
  const add = (key: keyof UsageAccumulator, delta: unknown) => {
    const n = finite(delta);
    if (n === undefined) return;
    next[key] = (next[key] ?? 0) + n;
  };
  add("input", usage.input);
  add("cachedInput", usage.cacheRead);
  add("cacheWrite", usage.cacheWrite);
  add("output", usage.output);
  add("reasoning", usage.reasoning);
  add("cost", usage.cost?.total);
  return next;
}

/**
 * Build the wire payload from pi's context reading and the accumulated session
 * sums.
 *
 * Fields are OMITTED, never zeroed, when pi has no reading: `getContextUsage()`
 * returns null tokens right after compaction until a fresh assistant response
 * lands, and a 0 there would render as an empty context bar rather than as
 * "not measured yet".
 *
 * `totals.total` is `input + cachedInput + cacheWrite + output` — the same
 * arithmetic pi's `/sessions` uses, so the two agree to the token.
 *
 * The `input` it REPORTS is pi's `input + cacheRead + cacheWrite`, i.e. every
 * prompt token, because makit treats cached input as a SUBSET of input (that is
 * codex's shape, and what the panel's cache-share bar divides by). pi splits the
 * two instead, so passing its `input` through would draw a 33M cache row nested
 * under a 360-token parent. `reasoning` is excluded from `total`, being already
 * inside `output`.
 *
 * Returns `undefined` when nothing at all is known, so the caller can skip the
 * request instead of posting a snapshot that would be rejected as empty.
 */
export function buildUsage(
  usage: PiContextUsage | undefined | null,
  acc: UsageAccumulator,
  currency = "USD",
): UsagePayload | undefined {
  const contextTokens = finite(usage?.tokens);
  const contextWindow = finite(usage?.contextWindow);

  const prompt = [acc.input, acc.cachedInput, acc.cacheWrite].filter((v) => v !== undefined) as number[];
  const counted: UsagePayload["totals"] = {
    ...(prompt.length ? { input: prompt.reduce((sum, v) => sum + v, 0) } : {}),
    ...(acc.cachedInput !== undefined ? { cachedInput: acc.cachedInput } : {}),
    ...(acc.cacheWrite !== undefined ? { cacheWrite: acc.cacheWrite } : {}),
    ...(acc.output !== undefined ? { output: acc.output } : {}),
  };
  const totals: NonNullable<UsagePayload["totals"]> = {
    ...(counted.input !== undefined || counted.output !== undefined
      ? { total: (counted.input ?? 0) + (counted.output ?? 0) }
      : {}),
    ...counted,
    ...(acc.reasoning !== undefined ? { reasoning: acc.reasoning } : {}),
  };

  const payload: UsagePayload = {
    ...(contextTokens !== undefined ? { contextTokens } : {}),
    ...(contextWindow !== undefined ? { contextWindow } : {}),
    ...(Object.keys(totals).length ? { totals } : {}),
    ...(acc.cost !== undefined ? { cost: { amount: acc.cost, currency } } : {}),
  };
  return Object.keys(payload).length ? payload : undefined;
}

/**
 * True when `next` is worth sending given the last payload sent.
 *
 * pi fires `turn_end` once per turn, and a turn that only ran tools can leave
 * every reading unchanged. Suppressing those keeps one HTTP round trip per real
 * change rather than per turn.
 */
export function isWorthSending(last: UsagePayload | undefined, next: UsagePayload): boolean {
  if (!last) return true;
  return (
    last.contextTokens !== next.contextTokens ||
    last.contextWindow !== next.contextWindow ||
    last.cost?.amount !== next.cost?.amount ||
    // Safe because both sides are always `buildUsage` output, which inserts these
    // keys in a fixed order. Worst case if that ever stops holding is one
    // redundant loopback POST of a correct reading (the server is latest-wins);
    // it cannot report a CHANGE as unchanged, which is the failure that would
    // strand a stale number in the UI.
    JSON.stringify(last.totals) !== JSON.stringify(next.totals)
  );
}
