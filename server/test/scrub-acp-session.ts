/**
 * scrub-acp-session — sanitize raw `pi-acp` recordings before committing them:
 *   - drop the pi startup-banner agent_message_chunk (skills/prompts/extensions dump)
 *   - drop personal `skill:*` entries from available_commands_update (keep built-ins)
 *   - rewrite machine-specific absolute paths to stable placeholders
 *
 * Operates in place:
 *   node_modules/.bin/tsx test/scrub-acp-session.ts test/acp-sessions/*.jsonl
 *
 * Paths are taken from the environment, never hardcoded: the repo root (from
 * `--repo` or git) becomes `/repo` and `$HOME` becomes `/home/user`.
 */

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

function repoRoot(explicit?: string): string {
  if (explicit) return resolve(explicit);
  const here = dirname(fileURLToPath(import.meta.url));
  return execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: here, encoding: "utf8" }).trim();
}

/** Longest path first, so a home-nested repo root is replaced before `$HOME`. */
function pathRewrites(root: string): Array<[string, string]> {
  return [
    [root, "/repo"],
    [homedir(), "/home/user"],
  ].sort((a, b) => b[0].length - a[0].length) as Array<[string, string]>;
}

function isBanner(update: Record<string, unknown>): boolean {
  if (update.sessionUpdate !== "agent_message_chunk") return false;
  const content = update.content;
  const text =
    content && typeof content === "object" ? String((content as { text?: unknown }).text ?? "") : "";
  return text.startsWith("pi v") && text.includes("## Skills");
}

/** Returns the scrubbed line object, or null to drop the line entirely. */
export function scrubLine(obj: Record<string, unknown>): Record<string, unknown> | null {
  if (obj.t !== "update") return obj;
  const update = obj.update as Record<string, unknown>;
  if (isBanner(update)) return null;
  if (update.sessionUpdate === "available_commands_update") {
    const commands = (update.availableCommands as Array<{ name?: unknown }> | undefined) ?? [];
    update.availableCommands = commands.filter((c) => !String(c.name ?? "").startsWith("skill:"));
  }
  return obj;
}

export function scrubJsonl(jsonl: string, root: string): string {
  const rewrites = pathRewrites(root);
  const out: string[] = [];
  for (const line of jsonl.split("\n")) {
    if (!line.trim()) continue;
    const obj = scrubLine(JSON.parse(line) as Record<string, unknown>);
    if (!obj) continue;
    let text = JSON.stringify(obj);
    for (const [from, to] of rewrites) text = text.split(from).join(to);
    out.push(text);
  }
  return out.join("\n") + "\n";
}

if (process.argv[1]?.endsWith("scrub-acp-session.ts")) {
  const args = process.argv.slice(2);
  const repoIdx = args.indexOf("--repo");
  const root = repoRoot(repoIdx >= 0 ? args[repoIdx + 1] : undefined);
  const files = args.filter((_, i) => repoIdx < 0 || (i !== repoIdx && i !== repoIdx + 1));
  if (files.length === 0) throw new Error("usage: scrub-acp-session.ts [--repo <path>] <session.jsonl…>");
  for (const file of files) {
    const scrubbed = scrubJsonl(readFileSync(file, "utf8"), root);
    writeFileSync(file, scrubbed);
    console.error(`[scrub] ${file} (${scrubbed.trimEnd().split("\n").length} lines)`);
  }
}
