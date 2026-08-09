/**
 * T14 (SPEC-46) — `makit send`: post a message to a session (`send.message`).
 *
 * `--attach` (SPEC-33) uploads the bytes to `POST /media` on the same HTTPS
 * listener that carries the socket, then references the returned `mediaId` on the
 * turn. The failure modes matter more than the happy path: a file that cannot be
 * uploaded must **refuse the turn**, never send it as text-only — that would turn
 * "why is this misaligned?" into a question about an image the agent never got,
 * and the user would read a confident answer about nothing.
 */
import { test } from "node:test";
import assert from "node:assert/strict";

import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { parseSendArgs, runSend } from "./send.js";
import { withCliHome, captureCli } from "../../test/support/cli_home.js";
import { startStubWss } from "../../test/support/stub_wss.js";

interface Run {
  out: string;
  err: string;
  code: number;
  cmds: Record<string, unknown>[];
}

async function run(
  argv: string[],
  opts: { err?: string; mediaId?: string } = {},
): Promise<Run & { uploads: { mime: string; auth?: string; bytes: number }[] }> {
  const cmds: Record<string, unknown>[] = [];
  const stub = await startStubWss({
    acceptBearer: "CACHED",
    mediaId: opts.mediaId,
    onCmd: (m) => {
      cmds.push(m);
      return opts.err ? { __err: opts.err } : {};
    },
  });
  try {
    const cap = await captureCli(() => withCliHome(() => runSend([...argv, "--port", String(stub.port)])));
    return { ...cap, cmds, uploads: stub.uploads };
  } finally {
    await stub.close();
  }
}

const sent = (cmds: Record<string, unknown>[], kind: string) => cmds.find((c) => c.kind === kind);

test("parseSendArgs: id positional, -m message, --attach collects files", () => {
  const a = parseSendArgs(["s1", "-m", "hello", "--attach", "a.png", "--attach", "b.png"]);
  assert.equal(a.sessionId, "s1");
  assert.equal(a.message, "hello");
  assert.deepEqual(a.attach, ["a.png", "b.png"]);
});

test("send posts send.message with the session id and text", async () => {
  const r = await run(["s1", "-m", "fix the migration"]);
  assert.equal(r.code, 0, r.err);
  const msg = sent(r.cmds, "send.message")!;
  assert.equal(msg.sessionId, "s1");
  assert.equal(msg.text, "fix the migration");
});

test("a missing id or message is a usage error (exit 2), nothing sent", async () => {
  assert.equal((await run(["-m", "hi"])).code, 2);
  assert.equal((await run(["s1"])).code, 2);
  const r = await run(["s1"]);
  assert.equal(r.cmds.length, 0);
});

test("--attach uploads the bytes and references the returned mediaId on the turn", async () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-attach-"));
  const shot = join(dir, "shot.png");
  writeFileSync(shot, Buffer.from([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]));
  try {
    const r = await run(["s1", "-m", "why is this misaligned?", "--attach", shot], { mediaId: "abc123" });
    assert.equal(r.code, 0, r.err);
    assert.equal(r.uploads.length, 1);
    assert.equal(r.uploads[0]!.mime, "image/png", "mime comes from the extension; the server never sniffs");
    assert.equal(r.uploads[0]!.auth, "Bearer CACHED", "the upload carries the CLI's own credential");
    assert.equal(r.uploads[0]!.bytes, 7);
    const msg = r.cmds.find((c) => c.kind === "send.message")!;
    assert.equal(msg.text, "why is this misaligned?");
    assert.deepEqual(msg.attachments, [{ mediaId: "abc123", name: "shot.png" }]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("several --attach files each become one attachment, in order", async () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-attach-"));
  const a = join(dir, "a.png");
  const b = join(dir, "b.jpg");
  writeFileSync(a, Buffer.from([1]));
  writeFileSync(b, Buffer.from([2, 3]));
  try {
    const r = await run(["s1", "-m", "two", "--attach", a, "--attach", b], { mediaId: "same-id" });
    assert.deepEqual(r.uploads.map((u) => u.mime), ["image/png", "image/jpeg"]);
    const msg = r.cmds.find((c) => c.kind === "send.message")!;
    assert.deepEqual(msg.attachments, [
      { mediaId: "same-id", name: "a.png" },
      { mediaId: "same-id", name: "b.jpg" },
    ]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a file type the server would not store is refused BEFORE the turn is sent", async () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-attach-"));
  const notes = join(dir, "notes.txt");
  writeFileSync(notes, "hello");
  try {
    const r = await run(["s1", "-m", "look", "--attach", notes], { mediaId: "abc123" });
    assert.equal(r.code, 2);
    assert.match(r.err, /png|jpeg|image/i, "the message names what IS accepted");
    assert.equal(r.uploads.length, 0, "nothing is uploaded");
    assert.equal(r.cmds.length, 0, "and no text-only turn is sent in its place");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a missing file is a usage error, not a turn about an image that never arrived", async () => {
  const r = await run(["s1", "-m", "look", "--attach", "/nope/missing.png"], { mediaId: "abc123" });
  assert.equal(r.code, 2);
  assert.equal(r.cmds.length, 0);
});

test("an upload the server rejects fails the whole send", async () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-attach-"));
  const shot = join(dir, "shot.png");
  writeFileSync(shot, Buffer.from([1]));
  try {
    // No `mediaId` configured → the stub answers 415, as the real store does for
    // anything outside its allowlist.
    const r = await run(["s1", "-m", "look", "--attach", shot]);
    assert.notEqual(r.code, 0);
    assert.equal(r.cmds.length, 0);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("an err frame (no_such_session) prints and exits non-zero", async () => {
  const r = await run(["nope", "-m", "hi"], { err: "no such session" });
  assert.notEqual(r.code, 0);
  assert.match(r.err, /no such session/);
});
