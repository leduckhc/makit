/**
 * Attachment materialiser tests (SPEC-user-attachments T4).
 *
 * The interesting cases are all adversarial or environmental: a client-supplied
 * filename is the only untrusted string that reaches the filesystem here, and
 * the git-exclude write has to work in a **linked worktree**, where `.git` is a
 * file rather than a directory.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

import { MediaStore } from "./store.js";
import {
  ATTACHMENTS_DIR,
  NoWorktreeError,
  excludeMakitDir,
  materialise,
  promptSuffix,
  safeName,
} from "./attach.js";

const png = Buffer.from("fake-png-bytes");

function tmp(prefix: string): string {
  return mkdtempSync(join(tmpdir(), `makit-attach-${prefix}-`));
}

/** A real repo with one commit — the precondition for adding a worktree. */
function initRepo(): string {
  const dir = tmp("repo");
  const g = (...args: string[]) => execFileSync("git", args, { cwd: dir, stdio: "ignore" });
  execFileSync("git", ["init", "-q", "-b", "main", dir], { stdio: "ignore" });
  g("config", "user.email", "t@example.com");
  g("config", "user.name", "T");
  writeFileSync(join(dir, "README.md"), "hi\n");
  g("add", "-A");
  g("commit", "-qm", "init");
  return dir;
}

function storeWith(bytes = png): { store: MediaStore; mediaId: string } {
  const store = new MediaStore({ dir: tmp("store") });
  return { store, mediaId: store.put(bytes, "image/png").mediaId };
}

// ---------- safeName --------------------------------------------------------

test("safeName reduces a hostile hint to a harmless filename", () => {
  // Each of these must not be able to escape the attachments directory, and
  // must not produce an empty name (which would create a directory-like path).
  const cases: [string | undefined, string][] = [
    ["shot.png", "shot.png"],
    ["../../etc/passwd", "etc-passwd.png"],
    ["..", "attachment.png"],
    ["...", "attachment.png"],
    ["/absolute/path.png", "absolute-path.png"],
    ["with spaces.png", "with-spaces.png"],
    ["émoji-🔥.png", "moji-.png"],
    [".hidden", "hidden.png"],
    ["", "attachment.png"],
    [undefined, "attachment.png"],
    ["no-extension", "no-extension.png"],
  ];
  for (const [hint, expected] of cases) {
    assert.equal(safeName(hint, "image/png"), expected, `hint=${JSON.stringify(hint)}`);
  }
});

test("safeName never yields a path separator, a traversal, or an empty string", () => {
  for (const hint of ["../../x", "a/b/c", "a\\b", "..", "....", "///", "\u0000null"]) {
    const out = safeName(hint, "image/png");
    assert.ok(out.length > 0, `empty for ${JSON.stringify(hint)}`);
    assert.ok(!out.includes("/") && !out.includes("\\"), out);
    assert.ok(!out.includes(".."), out);
  }
});

test("safeName picks the extension from the mime when the hint has none", () => {
  assert.equal(safeName("pic", "image/jpeg"), "pic.jpg");
  assert.equal(safeName("pic", "image/gif"), "pic.gif");
  assert.equal(safeName("pic", "image/webp"), "pic.webp");
});

test("safeName caps length so a 4 KB hint cannot make an unusable filename", () => {
  const out = safeName("a".repeat(4096), "image/png");
  assert.ok(out.length <= 70, `got ${out.length}`);
});

// ---------- materialise ----------------------------------------------------

test("materialise copies the blob into the worktree under a hash-prefixed name", () => {
  const { store, mediaId } = storeWith();
  const worktree = tmp("wt");
  const files = materialise(store, [{ mediaId, mime: "image/png", sizeBytes: png.length, name: "shot.png" }], worktree);

  assert.equal(files.length, 1);
  assert.equal(files[0]!.name, `${mediaId.slice(0, 7)}-shot.png`);
  assert.equal(files[0]!.absPath, join(worktree, ATTACHMENTS_DIR, files[0]!.name));
  assert.deepEqual(readFileSync(files[0]!.absPath), png);
});

test("materialise never writes outside the attachments directory, whatever the hint", () => {
  const { store, mediaId } = storeWith();
  const worktree = tmp("wt");
  const expectedDir = resolve(worktree, ATTACHMENTS_DIR);
  for (const name of ["../../escape.png", "/etc/passwd", "..", "a/b.png"]) {
    const [file] = materialise(
      store,
      [{ mediaId, mime: "image/png", sizeBytes: png.length, name }],
      worktree,
    );
    assert.equal(dirname(resolve(file!.absPath)), expectedDir, `name=${name}`);
    assert.ok(existsSync(file!.absPath));
  }
});

test("two different blobs with the same display name do not collide", () => {
  const store = new MediaStore({ dir: tmp("store") });
  const a = store.put(Buffer.from("one"), "image/png");
  const b = store.put(Buffer.from("two"), "image/png");
  const worktree = tmp("wt");
  const files = materialise(
    store,
    [
      { ...a, name: "screenshot.png" },
      { ...b, name: "screenshot.png" },
    ],
    worktree,
  );
  assert.notEqual(files[0]!.absPath, files[1]!.absPath);
  assert.deepEqual(readFileSync(files[0]!.absPath), Buffer.from("one"));
  assert.deepEqual(readFileSync(files[1]!.absPath), Buffer.from("two"));
});

test("re-attaching the same blob is idempotent", () => {
  const { store, mediaId } = storeWith();
  const worktree = tmp("wt");
  const one = materialise(store, [{ mediaId, mime: "image/png", sizeBytes: png.length }], worktree);
  const two = materialise(store, [{ mediaId, mime: "image/png", sizeBytes: png.length }], worktree);
  assert.equal(one[0]!.absPath, two[0]!.absPath);
  assert.deepEqual(readFileSync(two[0]!.absPath), png);
});

test("no attachments is a no-op that does not require a worktree", () => {
  const { store } = storeWith();
  assert.deepEqual(materialise(store, [], undefined), []);
});

test("attachments with no worktree throw NoWorktreeError, never silently drop", () => {
  const { store, mediaId } = storeWith();
  assert.throws(
    () => materialise(store, [{ mediaId, mime: "image/png", sizeBytes: png.length }], undefined),
    NoWorktreeError,
  );
});

// ---------- git exclude ----------------------------------------------------

test("excludeMakitDir adds .makit/ to info/exclude and is idempotent", () => {
  const repo = initRepo();
  excludeMakitDir(repo);
  excludeMakitDir(repo);
  const exclude = readFileSync(join(repo, ".git", "info", "exclude"), "utf8");
  const hits = exclude.split(/\r?\n/).filter((l) => l.trim() === ".makit/");
  assert.equal(hits.length, 1, "appended exactly once");
});

test("a materialised attachment leaves `git status` clean in a LINKED worktree", () => {
  // The case that breaks naive implementations: in a linked worktree `.git` is a
  // FILE pointing at <main>/.git/worktrees/<name>, so the exclude file is not at
  // <root>/.git/info/exclude.
  const repo = initRepo();
  const wt = join(tmp("wtparent"), "feature");
  execFileSync("git", ["worktree", "add", "-q", "-b", "feature", wt], {
    cwd: repo,
    stdio: "ignore",
  });
  assert.ok(!existsSync(join(wt, ".git", "info")), "sanity: linked worktree has a .git FILE");

  const { store, mediaId } = storeWith();
  materialise(store, [{ mediaId, mime: "image/png", sizeBytes: png.length, name: "s.png" }], wt);

  const status = execFileSync("git", ["status", "--porcelain"], { cwd: wt, encoding: "utf8" });
  assert.equal(status.trim(), "", `worktree must stay clean, got:\n${status}`);
});

test("excludeMakitDir on a non-repo directory is a no-op, not a throw", () => {
  const plain = tmp("plain");
  assert.doesNotThrow(() => excludeMakitDir(plain));
});

test("materialise works in a plain (non-git) directory", () => {
  // Not every session worktree is guaranteed to be a repo; delivery must not
  // depend on git succeeding.
  const { store, mediaId } = storeWith();
  const plain = tmp("plain");
  const [file] = materialise(store, [{ mediaId, mime: "image/png", sizeBytes: png.length }], plain);
  assert.deepEqual(readFileSync(file!.absPath), png);
});

test("an existing info/exclude without a trailing newline is not corrupted", () => {
  const repo = initRepo();
  const excludePath = join(repo, ".git", "info", "exclude");
  mkdirSync(dirname(excludePath), { recursive: true });
  writeFileSync(excludePath, "*.log"); // no trailing newline
  excludeMakitDir(repo);
  const lines = readFileSync(excludePath, "utf8").split(/\r?\n/);
  assert.ok(lines.includes("*.log"), "pre-existing rule survives intact");
  assert.ok(lines.includes(".makit/"));
});

// ---------- promptSuffix ---------------------------------------------------

test("promptSuffix names every file on its own line, absolute", () => {
  const suffix = promptSuffix([
    { absPath: "/w/.makit/attachments/abc-1.png", name: "abc-1.png" },
    { absPath: "/w/.makit/attachments/def-2.png", name: "def-2.png" },
  ]);
  assert.equal(
    suffix,
    "\n\nAttached files:\n- /w/.makit/attachments/abc-1.png\n- /w/.makit/attachments/def-2.png",
  );
});

test("promptSuffix is empty for no files, so callers can concatenate blindly", () => {
  assert.equal(promptSuffix([]), "");
  assert.equal(`text${promptSuffix([])}`, "text");
});
