/**
 * T8 (SPEC-cli-as-client) — the credential defect `attach` used to have, locked shut.
 *
 * `readBearer()` read `~/.makit/devices.json` and took `arr[0].bearer` — the
 * *phone's* credential (spec §2). So revoking the phone killed the CLI, revoking
 * the CLI was impossible, and capability checks had no subject. `attach` now
 * connects through `cli/connect.ts` like every other verb; this grep test is the
 * regression lock that no CLI code path reads that file again.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

test("no file under src/cli reads devices.json (the §2 defect stays deleted)", () => {
  const dir = new URL(".", import.meta.url).pathname;
  // Comments are stripped first: the *prose* explaining the deleted hack must
  // stay readable, it is only a code path reading the file that is forbidden.
  const code = (src: string) => src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
  const offenders = readdirSync(dir)
    .filter((f) => f.endsWith(".ts") && !f.endsWith(".test.ts"))
    .filter((f) => code(readFileSync(join(dir, f), "utf8")).includes("devices.json"));
  assert.deepEqual(offenders, [], `these read the phone's credential: ${offenders.join(", ")}`);
});
