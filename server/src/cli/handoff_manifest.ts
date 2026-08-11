/**
 * Pure parse + render for the SPEC-46 handoff manifest (D5). Kept free of I/O so
 * it can be unit-tested without a server, mirroring `render.ts`.
 *
 * The producer is an LLM writing the manifest that becomes the *entire*
 * interchange between two agents, so parsing is total and lenient: unknown keys
 * are dropped, wrong types are dropped, and no input ever throws — a rejected
 * handoff would lose the very context it was built from. Rendering is
 * deterministic (fixed section order, missing sections omitted) because it is
 * what a human reads on their phone to understand a session they never started.
 */
import type { SessionEvent } from "../protocol.js";


export interface HandoffManifest {
  goal?: string;
  done?: string[];
  next?: string[];
  files?: string[];
  gotchas?: string[];
  openQuestions?: string[];
}

/** A string with content, else undefined. */
function asText(v: unknown): string | undefined {
  if (typeof v !== "string") return undefined;
  const t = v.trim();
  return t.length > 0 ? t : undefined;
}

/** An array's string entries with content, else undefined if none survive. */
function asList(v: unknown): string[] | undefined {
  if (!Array.isArray(v)) return undefined;
  const items = v.map(asText).filter((s): s is string => s !== undefined);
  return items.length > 0 ? items : undefined;
}

/** Coerce an unknown JSON value into a manifest. Never throws. */
export function parseManifest(input: unknown): HandoffManifest {
  if (typeof input !== "object" || input === null || Array.isArray(input)) return {};
  const o = input as Record<string, unknown>;
  const m: HandoffManifest = {};
  if (asText(o.goal) !== undefined) m.goal = asText(o.goal);
  if (asList(o.done) !== undefined) m.done = asList(o.done);
  if (asList(o.next) !== undefined) m.next = asList(o.next);
  if (asList(o.files) !== undefined) m.files = asList(o.files);
  if (asList(o.gotchas) !== undefined) m.gotchas = asList(o.gotchas);
  if (asList(o.openQuestions) !== undefined) m.openQuestions = asList(o.openQuestions);
  return m;
}

// Fixed reading order: the goal (what), what's already Done, what's Next, the
// Files to look at, the Gotchas that bite, and the Open questions left behind.
const LIST_SECTIONS: ReadonlyArray<[keyof HandoffManifest, string]> = [
  ["done", "Done"],
  ["next", "Next"],
  ["files", "Files"],
  ["gotchas", "Gotchas"],
  ["openQuestions", "Open questions"],
];

/** Render a manifest to deterministic markdown. Missing sections are omitted. */
export function renderManifest(m: HandoffManifest): string {
  const blocks: string[] = [];
  if (m.goal !== undefined) blocks.push(`## Goal\n\n${m.goal}`);
  for (const [key, heading] of LIST_SECTIONS) {
    const items = m[key] as string[] | undefined;
    if (items !== undefined) {
      blocks.push(`## ${heading}\n\n${items.map((i) => `- ${i}`).join("\n")}`);
    }
  }
  return blocks.length > 0 ? blocks.join("\n\n") + "\n" : "";
}

/**
 * The `--carry last:N` excerpt: a fenced block of the parent's last events, as
 * **quoted context in a message** — never replayed as agent state (D5). Fenced
 * so the receiving agent cannot mistake the parent's turns for its own
 * instructions, and one line per event so a phone can read it.
 */
export function renderTranscriptExcerpt(events: readonly SessionEvent[]): string {
  if (events.length === 0) return "";
  const lines = events.map((e) => {
    const p = e.payload as Record<string, unknown>;
    const text = [p.text, p.chunk, p.summary, p.name, p.message, p.status].find(
      (v): v is string => typeof v === "string" && v.trim().length > 0,
    );
    const body = text ? ` ${text.replace(/\s+/g, " ").trim()}` : "";
    return `[${e.seq}] ${e.kind}${body}`;
  });
  return `## Transcript excerpt (last ${events.length})\n\n\`\`\`\n${lines.join("\n")}\n\`\`\`\n`;
}
