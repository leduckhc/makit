/**
 * Build a filtered copy of pi's agent config dir that excludes specific
 * packages (e.g. `@mammothb/pi-ask`, which is TUI-only and crashes under
 * pino's headless rpc — see docs/UI-TRANSPORT.md).
 *
 * Rather than reimplement pi's package resolver (globs, skills, prompts,
 * themes) via `-ne` + explicit `-e`, we let pi do all its own discovery from a
 * temp agent dir that symlinks everything from the real dir EXCEPT
 * `settings.json`, which we rewrite with the offending packages removed.
 *
 * Local (relative) package paths are rewritten to absolute so they still
 * resolve when the agent dir moves to a temp location.
 */

import {
  mkdirSync,
  readdirSync,
  symlinkSync,
  writeFileSync,
  readFileSync,
  rmSync,
  existsSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, resolve, isAbsolute } from "node:path";

/**
 * @returns the path to the filtered agent dir (set as PI_CODING_AGENT_DIR),
 *   or `undefined` if the real agent dir / settings can't be read (caller
 *   should then fall back to pi's default discovery).
 */
export function buildFilteredAgentDir(excludePackages: string[]): string | undefined {
  const src = process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent");
  const settingsPath = join(src, "settings.json");
  if (!existsSync(settingsPath)) return undefined;

  const dest = join(tmpdir(), "pino-pi-agent");
  rmSync(dest, { recursive: true, force: true });
  mkdirSync(dest, { recursive: true });

  // Symlink every entry except settings.json (which we filter).
  for (const entry of readdirSync(src)) {
    if (entry === "settings.json") continue;
    try {
      symlinkSync(join(src, entry), join(dest, entry));
    } catch {
      // Best-effort; skip entries we can't symlink.
    }
  }

  const settings = JSON.parse(readFileSync(settingsPath, "utf8"));
  if (Array.isArray(settings.packages)) {
    settings.packages = settings.packages
      .filter((p: unknown) => {
        if (typeof p !== "string") return true;
        // Match by package name (npm:@scope/name or npm:plain or relative/path).
        return !excludePackages.some((ex) => 
          p === ex || 
          p === `npm:${ex}` || 
          p.endsWith(`/${ex}`),
        );
      })
      // Rewrite relative local package paths to absolute (they were relative
      // to the real agent dir; the temp dir would resolve them elsewhere).
      .map((p: string) =>
        p.startsWith("npm:") || isAbsolute(p) ? p : resolve(src, p),
      );
  }
  writeFileSync(join(dest, "settings.json"), JSON.stringify(settings, null, 2));
  return dest;
}
