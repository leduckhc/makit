import assert from "node:assert/strict";
import { test } from "node:test";

import { adoptLoginShellPathIfMinimal, isMinimalPath, loginShellPath } from "./login_path.js";

/** launchd hands a GUI-launched app exactly this PATH. */
const LAUNCHD_PATH = "/usr/bin:/bin:/usr/sbin:/sbin";
const RICH_PATH = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin";

test("isMinimalPath: launchd's system-only PATH is minimal", () => {
  assert.equal(isMinimalPath(LAUNCHD_PATH), true);
  assert.equal(isMinimalPath("/bin:/usr/bin/"), true, "trailing slashes still match");
});

test("isMinimalPath: an absent or empty PATH is minimal", () => {
  assert.equal(isMinimalPath(undefined), true);
  assert.equal(isMinimalPath(""), true);
});

test("isMinimalPath: one user dir is enough to be a real PATH", () => {
  assert.equal(isMinimalPath(RICH_PATH), false);
  assert.equal(isMinimalPath("/usr/bin:/bin:/Users/me/.local/bin"), false);
});

test("loginShellPath: extracts the PATH between markers, ignoring rc-file noise", () => {
  const seen: Array<{ shell: string; args: string[] }> = [];
  const got = loginShellPath({
    env: { SHELL: "/bin/zsh" },
    run: (shell, args) => {
      seen.push({ shell, args });
      return `zsh: welcome banner\n__MAKIT_PATH_BEGIN__${RICH_PATH}__MAKIT_PATH_END__\ntrailing noise\n`;
    },
  });
  assert.equal(got, RICH_PATH);
  assert.equal(seen.length, 1);
  assert.equal(seen[0].shell, "/bin/zsh");
  assert.ok(
    seen[0].args.includes("-ilc"),
    "must run an interactive login shell so ~/.zshrc PATH edits are seen",
  );
});

test("loginShellPath: no SHELL, unparseable output, or a throwing shell yields undefined", () => {
  assert.equal(loginShellPath({ env: {}, run: () => RICH_PATH }), undefined);
  assert.equal(loginShellPath({ env: { SHELL: "/bin/zsh" }, run: () => "no markers here" }), undefined);
  assert.equal(
    loginShellPath({
      env: { SHELL: "/bin/zsh" },
      run: () => {
        throw new Error("shell timed out");
      },
    }),
    undefined,
  );
});

test("adoptLoginShellPathIfMinimal: replaces a launchd PATH with the login shell's", () => {
  const env: NodeJS.ProcessEnv = { SHELL: "/bin/zsh", PATH: LAUNCHD_PATH };
  const adopted = adoptLoginShellPathIfMinimal({
    env,
    run: () => `__MAKIT_PATH_BEGIN__${RICH_PATH}__MAKIT_PATH_END__`,
  });
  assert.equal(adopted, true);
  assert.equal(env.PATH, RICH_PATH);
});

test("adoptLoginShellPathIfMinimal: a real PATH is left alone and the shell is never run", () => {
  const env: NodeJS.ProcessEnv = { SHELL: "/bin/zsh", PATH: RICH_PATH };
  let ran = false;
  const adopted = adoptLoginShellPathIfMinimal({
    env,
    run: () => {
      ran = true;
      return "";
    },
  });
  assert.equal(adopted, false);
  assert.equal(env.PATH, RICH_PATH, "an existing real PATH is authoritative");
  assert.equal(ran, false, "spawning a login shell on every start would be pure cost");
});

test("adoptLoginShellPathIfMinimal: a shell that answers with a minimal PATH changes nothing", () => {
  const env: NodeJS.ProcessEnv = { SHELL: "/bin/sh", PATH: LAUNCHD_PATH };
  const adopted = adoptLoginShellPathIfMinimal({
    env,
    run: () => `__MAKIT_PATH_BEGIN__${LAUNCHD_PATH}__MAKIT_PATH_END__`,
  });
  assert.equal(adopted, false);
  assert.equal(env.PATH, LAUNCHD_PATH);
});
