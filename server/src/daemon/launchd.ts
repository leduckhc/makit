/**
 * macOS launchd LaunchAgent integration (SPEC-01, phase 5).
 *
 * `pino service install` writes a LaunchAgent plist to
 * `~/Library/LaunchAgents/dev.pino.plist`; `pino service uninstall` removes it.
 *
 * **Opt-in only** (consensus #2): the plist sets `RunAtLoad=false` and
 * `KeepAlive=false`, so installing it does NOT start pino and macOS will not
 * resurrect it. The user still starts/stops on demand via `pino start`/`stop`;
 * the LaunchAgent merely makes pino a `launchctl`-manageable label.
 *
 * ## Manual verification (not unit-tested — needs a real macOS session)
 *
 *   pino service install
 *   test -f ~/Library/LaunchAgents/dev.pino.plist   # written
 *   launchctl load ~/Library/LaunchAgents/dev.pino.plist
 *   pino status                                      # still "not running"
 *   launchctl start dev.pino && pino status          # now running
 *   launchctl stop dev.pino
 *   pino service uninstall                           # file removed
 */

import { writeFileSync, rmSync, existsSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

export const LAUNCH_AGENT_LABEL = "dev.pino";

export interface PlistOpts {
  label: string;
  execPath: string;
  entry: string;
  logPath: string;
}

/** Escape the five XML predefined entities so paths are plist-safe. */
function xmlEscape(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

/** Build the LaunchAgent plist XML. Pure — no filesystem side effects. */
export function buildLaunchAgentPlist(opts: PlistOpts): string {
  const args = [opts.execPath, opts.entry, "serve"]
    .map((a) => `    <string>${xmlEscape(a)}</string>`)
    .join("\n");
  const log = xmlEscape(opts.logPath);
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${xmlEscape(opts.label)}</string>
  <key>ProgramArguments</key>
  <array>
${args}
  </array>
  <key>RunAtLoad</key>
  <false/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>${log}</string>
  <key>StandardErrorPath</key>
  <string>${log}</string>
</dict>
</plist>
`;
}

export interface InstallOpts extends PlistOpts {
  plistPath: string;
}

/** Write the LaunchAgent plist. Does NOT load or start it. */
export function installService(opts: InstallOpts): void {
  mkdirSync(dirname(opts.plistPath), { recursive: true });
  writeFileSync(opts.plistPath, buildLaunchAgentPlist(opts));
}

/** Remove the LaunchAgent plist. Returns whether a file was actually removed. */
export function uninstallService(opts: { plistPath: string }): boolean {
  if (!existsSync(opts.plistPath)) return false;
  rmSync(opts.plistPath, { force: true });
  return true;
}
