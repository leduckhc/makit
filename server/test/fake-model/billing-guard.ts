/**
 * Shared billing guard for the real-agent scripts.
 *
 * These scripts are advertised as deterministic and keyless: they run the genuine
 * agent binary but point it at the local fake-model server. That swap currently
 * CANNOT take effect for pi — it runs behind `pi-acp`, which spawns pi with a
 * fixed argv and forwards no `-e`, so the fake provider extension never loads and
 * `makit-fake/fake-1` is never offered. The old behaviour was a silent fallback
 * to whatever model the operator has configured, i.e. real billable calls from a
 * loop documented as free.
 *
 * So: verify before the first prompt, and fail closed.
 */

/** Provider/model id registered by the fake-model provider extension. */
export const FAKE_MODEL = "makit-fake/fake-1";

/**
 * Abort unless the fake model is actually selected. `MAKIT_E2E_ALLOW_REAL_MODEL=1`
 * is the explicit opt-in for "yes, bill my provider".
 */
export function guardAgainstRealBilling(context: string, currentModel: string | undefined): void {
  if (currentModel === FAKE_MODEL) return;
  const msg =
    `[makit] ${context}: the fake model is NOT in effect (model=${currentModel ?? "unknown"}).\n` +
    `        pi-acp spawns pi with a fixed argv, so the fake provider extension never\n` +
    `        loads — prompting from here bills that provider for real.\n` +
    `        Re-run with MAKIT_E2E_ALLOW_REAL_MODEL=1 to accept that cost.`;
  if (process.env.MAKIT_E2E_ALLOW_REAL_MODEL === "1") {
    console.warn(msg);
    return;
  }
  console.error(msg);
  process.exit(1);
}

/** The current `model` config option from the newest `session.meta`, if any. */
export function currentModelFromEvents(
  events: readonly { kind: string; payload?: unknown }[],
): string | undefined {
  const meta = [...events].reverse().find((e) => e.kind === "session.meta");
  const options = (meta?.payload as { configOptions?: { id: string; currentValue?: string }[] } | undefined)
    ?.configOptions;
  return options?.find((o) => o.id === "model")?.currentValue;
}
