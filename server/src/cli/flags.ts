/**
 * The one argv scanner every `makit` verb uses.
 *
 * Before this, each verb hand-rolled the same `for` loop with `argv[++i]` —
 * fifty-nine such sites across sixteen files — and every one of them shared the
 * same defect: a flag in last position reads past the end, so `makit ls --port`
 * became port `NaN` and `makit send s1 -m` sent an agent the literal text
 * `"undefined"`. Validating that in `connectCli` fixed it for exactly the two
 * flags that happen to pass through there and left the other twenty-five broken;
 * a missing value is a property of *parsing*, so it is fixed here, once.
 *
 * Deliberately small and boring. It knows five value shapes and nothing about
 * any verb: `--timeout` seconds→ms and `--carry last:N` stay in the verbs that
 * own those meanings, and each verb still declares its own typed `Args`
 * interface. This replaces the index juggling, not the contract.
 *
 * Unknown flags are ignored, which is what the hand-written loops did — and is
 * load-bearing, because `run` parses one argv against two specs. Tightening that
 * is a behaviour change, not a refactor, so it is left alone.
 */
import { EXIT_USAGE } from "./exit-codes.js";

export type Flag =
  | { type: "string"; alias?: string; def?: string }
  | { type: "int"; alias?: string; def?: number }
  | { type: "bool"; alias?: string }
  | { type: "list"; alias?: string }
  | { type: "enum"; values: readonly string[]; alias?: string; def?: string };

export type Spec = Record<string, Flag>;

/** Parsed values, keyed as in the spec, plus every non-flag token in order. */
export interface Parsed {
  flags: Record<string, string | number | boolean | string[] | undefined>;
  positionals: string[];
}

/** Print the reason and exit `2` — a malformed command line, per D8. */
export function failUsage(message: string): never {
  console.error(`[makit] ${message}`);
  return process.exit(EXIT_USAGE);
}

/** The argv spelling(s) that select `name`, longest first so `--m` never shadows `-m`. */
function spellings(name: string, flag: Flag): string[] {
  return flag.alias ? [`--${name}`, flag.alias] : [`--${name}`];
}

export function parseFlags(argv: string[], spec: Spec): Parsed {
  const flags: Parsed["flags"] = {};
  const positionals: string[] = [];

  for (const [name, flag] of Object.entries(spec)) {
    if (flag.type === "bool") flags[name] = false;
    else if (flag.type === "list") flags[name] = [];
    else if ("def" in flag && flag.def !== undefined) flags[name] = flag.def;
  }

  for (let i = 0; i < argv.length; i++) {
    const token = argv[i]!;
    const hit = Object.entries(spec).find(([name, flag]) => spellings(name, flag).includes(token));
    if (!hit) {
      if (!token.startsWith("-")) positionals.push(token);
      continue;
    }
    const [name, flag] = hit;
    if (flag.type === "bool") {
      flags[name] = true;
      continue;
    }
    // The defect this module exists for: a flag that takes a value and has none.
    if (i + 1 >= argv.length) failUsage(`${token} needs a value`);
    const raw = argv[++i]!;
    if (flag.type === "string") flags[name] = raw;
    else if (flag.type === "list") (flags[name] as string[]).push(raw);
    else if (flag.type === "int") {
      const n = Number(raw);
      if (!Number.isFinite(n)) failUsage(`${token} must be a number, got: ${raw}`);
      flags[name] = n;
    } else {
      // An unknown enum value is refused, never widened to the default: a
      // misspelled `--for aproval` that silently became `any` would exit 0 on a
      // completed turn, sailing past the block the caller was waiting for.
      if (!flag.values.includes(raw)) {
        failUsage(`unknown ${token} value: ${raw} (expected ${flag.values.join("|")})`);
      }
      flags[name] = raw;
    }
  }
  return { flags, positionals };
}

/** Typed readers, so a verb assembles its own `Args` without casts. */
export const str = (p: Parsed, k: string): string | undefined =>
  typeof p.flags[k] === "string" ? (p.flags[k] as string) : undefined;
export const int = (p: Parsed, k: string): number | undefined =>
  typeof p.flags[k] === "number" ? (p.flags[k] as number) : undefined;
export const bool = (p: Parsed, k: string): boolean => p.flags[k] === true;
export const list = (p: Parsed, k: string): string[] =>
  Array.isArray(p.flags[k]) ? (p.flags[k] as string[]) : [];
