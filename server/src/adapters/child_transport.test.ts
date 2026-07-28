import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import type { ChildProcess } from "node:child_process";

import { spawnLineProcess } from "./child_transport.js";

/**
 * A fake ChildProcess: an EventEmitter with pipe-shaped stdio streams, enough
 * for spawnLineProcess to bind its listeners. Captures stdin writes.
 */
function fakeSpawn(): {
  spawn: (typeof import("node:child_process"))["spawn"];
  children: any[];
  writes: string[];
} {
  const children: any[] = [];
  const writes: string[] = [];
  const spawn = ((command: string, args: string[]) => {
    const child: any = new EventEmitter();
    child.command = command;
    child.args = args;
    child.killed = false;
    child.stdin = Object.assign(new EventEmitter(), {
      destroyed: false,
      writable: true,
      write: (s: string) => {
        writes.push(s);
        return true;
      },
      end: () => {},
    });
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();
    child.kill = () => {
      child.killed = true;
    };
    children.push(child);
    return child as unknown as ChildProcess;
  }) as unknown as (typeof import("node:child_process"))["spawn"];
  return { spawn, children, writes };
}

test("spawnLineProcess splits stdout on LF only (not on U+2028/U+2029)", () => {
  const { spawn, children } = fakeSpawn();
  const t = spawnLineProcess({ command: "x", cwd: "/tmp", label: "t", spawn });
  const lines: string[] = [];
  t.onLine((l) => lines.push(l));

  const child = children[0]!;
  // A JSON payload containing a raw U+2028 must NOT be split.
  child.stdout.emit("data", '{"a":"x\u2028y"}\n{"b":1}\n');
  assert.deepEqual(lines, ['{"a":"x\u2028y"}', '{"b":1}']);
});

test("spawnLineProcess buffers a partial line across chunks and strips a trailing CR", () => {
  const { spawn, children } = fakeSpawn();
  const t = spawnLineProcess({ command: "x", cwd: "/tmp", label: "t", spawn });
  const lines: string[] = [];
  t.onLine((l) => lines.push(l));

  const child = children[0]!;
  child.stdout.emit("data", '{"part":');
  child.stdout.emit("data", '1}\r\n');
  assert.deepEqual(lines, ['{"part":1}']);
});

test("spawnLineProcess sends a line with a trailing newline", () => {
  const { spawn, writes } = fakeSpawn();
  const t = spawnLineProcess({ command: "x", cwd: "/tmp", label: "t", spawn });
  t.send('{"cmd":1}');
  assert.deepEqual(writes, ['{"cmd":1}\n']);
});

test("onExit fires once with the exit code; a late registrant is replayed", () => {
  const { spawn, children } = fakeSpawn();
  const t = spawnLineProcess({ command: "x", cwd: "/tmp", label: "t", spawn });
  const early: number[] = [];
  t.onExit((code) => early.push(code!));

  children[0]!.emit("exit", 3, null);
  // A second 'exit' must not re-fire (settle-once).
  children[0]!.emit("exit", 9, null);
  assert.deepEqual(early, [3]);

  // A listener registered AFTER the process exited is replayed the code.
  const late: Array<number | null> = [];
  t.onExit((code) => late.push(code));
  assert.deepEqual(late, [3]);
});

test("a spawn/process 'error' settles onExit with code=null and the error info", () => {
  const { spawn, children } = fakeSpawn();
  const t = spawnLineProcess({ command: "x", cwd: "/tmp", label: "t", spawn });
  const seen: Array<{ code: number | null; msg?: string }> = [];
  t.onExit((code, info) => seen.push({ code, msg: info.error?.message }));

  children[0]!.emit("error", Object.assign(new Error("spawn ENOENT"), { code: "ENOENT" }));
  assert.equal(seen.length, 1);
  assert.equal(seen[0].code, null);
  assert.equal(seen[0].msg, "spawn ENOENT");
});

test("exit info carries the stderr tail for diagnostics", () => {
  const { spawn, children } = fakeSpawn();
  const t = spawnLineProcess({ command: "x", cwd: "/tmp", label: "t", spawn });
  let tail = "";
  t.onExit((_code, info) => (tail = info.stderrTail));

  const child = children[0]!;
  child.stderr.emit("data", Buffer.from("boom: bad thing\n"));
  child.emit("exit", 1, null);
  assert.match(tail, /boom: bad thing/);
});

test("EPIPE on stdin / read faults on stdout/stderr are swallowed (no throw)", () => {
  const { spawn, children } = fakeSpawn();
  spawnLineProcess({ command: "x", cwd: "/tmp", label: "t", spawn });
  const child = children[0]!;
  assert.doesNotThrow(() =>
    child.stdin.emit("error", Object.assign(new Error("write EPIPE"), { code: "EPIPE" })),
  );
  assert.doesNotThrow(() => child.stdout.emit("error", new Error("read EIO")));
  assert.doesNotThrow(() => child.stderr.emit("error", new Error("read EIO")));
});

test("send after the stream is destroyed is a no-op (never throws)", () => {
  const { spawn, children } = fakeSpawn();
  const t = spawnLineProcess({ command: "x", cwd: "/tmp", label: "t", spawn });
  children[0]!.stdin.destroyed = true;
  assert.doesNotThrow(() => t.send("late"));
});

test("onStreamEnd fires after the final unterminated line is flushed", () => {
  const { spawn, children } = fakeSpawn();
  const t = spawnLineProcess({ command: "x", cwd: "/tmp", label: "t", spawn });
  const order: string[] = [];
  t.onLine((l) => order.push(`line:${l}`));
  t.onStreamEnd(() => order.push("end"));

  const child = children[0]!;
  // 'exit' before stdout drains — must NOT end the stream.
  child.emit("exit", 0, null);
  child.stdout.emit("data", '{"late":1}\n{"tail":2}');
  child.stdout.emit("end");
  assert.deepEqual(order, ['line:{"late":1}', 'line:{"tail":2}', "end"]);
});

test("onStreamEnd settles once, replays to late registrants, and fires on stdout 'close'", () => {
  const { spawn, children } = fakeSpawn();
  const t = spawnLineProcess({ command: "x", cwd: "/tmp", label: "t", spawn });
  const order: string[] = [];
  t.onLine((l) => order.push(`line:${l}`));
  t.onStreamEnd(() => order.push("end"));

  const child = children[0]!;
  // A destroyed-without-'end' stream (e.g. failed spawn) still settles via
  // 'close' — and the pending partial line is flushed BEFORE settlement.
  child.stdout.emit("data", '{"partial":1}');
  child.stdout.emit("close");
  child.stdout.emit("end"); // second signal must not re-fire or re-flush
  assert.deepEqual(order, ['line:{"partial":1}', "end"]);

  let late = 0;
  t.onStreamEnd(() => late++); // registered after settle → replayed
  assert.equal(late, 1);
});

test("a spawn fault (child 'error') settles onStreamEnd", () => {
  const { spawn, children } = fakeSpawn();
  const t = spawnLineProcess({ command: "x", cwd: "/tmp", label: "t", spawn });
  let ended = false;
  t.onStreamEnd(() => (ended = true));

  children[0]!.emit("error", Object.assign(new Error("spawn ENOENT"), { code: "ENOENT" }));
  assert.equal(ended, true);
});

test("dispose kills the child", () => {
  const { spawn, children } = fakeSpawn();
  const t = spawnLineProcess({ command: "x", cwd: "/tmp", label: "t", spawn });
  t.dispose();
  assert.equal(children[0]!.killed, true);
});

test("an oversized unterminated frame is dropped instead of growing buf unbounded", () => {
  const { spawn, children } = fakeSpawn();
  const t = spawnLineProcess({
    command: "x",
    cwd: "/tmp",
    label: "t",
    spawn,
    maxFrameBytes: 1024,
  });
  const lines: string[] = [];
  t.onLine((l) => lines.push(l));

  const child = children[0]!;
  // A frame far larger than the cap, with no LF, must NOT be buffered forever.
  child.stdout.emit("data", "a".repeat(4096));
  child.stdout.emit("data", "a".repeat(4096) + "\n");
  // A well-formed line AFTER the oversized frame is dropped must still parse.
  child.stdout.emit("data", '{"ok":1}\n');
  assert.deepEqual(lines, ['{"ok":1}'], "oversized frame dropped; subsequent line delivered");
});

test("a multi-MB frame (base64 image block in a tool result) is delivered, not dropped", () => {
  const { spawn, children } = fakeSpawn();
  // Default cap — this is the real production path, not a test override.
  const t = spawnLineProcess({ command: "x", cwd: "/tmp", label: "t", spawn });
  const lines: string[] = [];
  t.onLine((l) => lines.push(l));

  // An ACP `tool_call_update {status:"completed"}` carrying a screenshot as
  // base64 in `rawOutput.content[]`. Dropping it doesn't just lose the image:
  // the terminal status update is lost too, so the tool call never ends.
  const payload = "A".repeat(8 * 1024 * 1024);
  const frame = JSON.stringify({ sessionUpdate: "tool_call_update", data: payload });
  const child = children[0]!;
  // Arrives in chunks, as a real stdout stream does.
  for (let i = 0; i < frame.length; i += 64 * 1024) {
    child.stdout.emit("data", frame.slice(i, i + 64 * 1024));
  }
  child.stdout.emit("data", "\n");

  assert.equal(lines.length, 1, "the multi-MB frame must be delivered");
  assert.equal(lines[0], frame);
});

test("a throwing onLine listener cannot escape and crash the process", () => {
  const { spawn, children } = fakeSpawn();
  const t = spawnLineProcess({ command: "x", cwd: "/tmp", label: "t", spawn });
  const seen: string[] = [];
  t.onLine(() => {
    throw new Error("consumer blew up");
  });
  t.onLine((l) => seen.push(l)); // a well-behaved second listener still runs

  const child = children[0]!;
  assert.doesNotThrow(() => child.stdout.emit("data", '{"a":1}\n'));
  assert.deepEqual(seen, ['{"a":1}']);
});

test("a throwing onExit listener cannot escape and crash the process", () => {
  const { spawn, children } = fakeSpawn();
  const t = spawnLineProcess({ command: "x", cwd: "/tmp", label: "t", spawn });
  let reached = false;
  t.onExit(() => {
    throw new Error("exit consumer blew up");
  });
  t.onExit(() => {
    reached = true;
  });
  assert.doesNotThrow(() => children[0]!.emit("exit", 0, null));
  assert.equal(reached, true, "a later exit listener still fires after an earlier one throws");
});

test("a newline-terminated frame over the cap is dropped, not delivered", () => {
  // The cap previously only guarded an *unterminated* buffer: a line whose
  // trailing newline arrived in the chunk that crossed the limit was still
  // dispatched, so a runaway child could push a frame past the stated bound.
  const { spawn, children } = fakeSpawn();
  const t = spawnLineProcess({
    command: "x",
    cwd: "/tmp",
    label: "t",
    spawn,
    maxFrameBytes: 1024,
  });
  const lines: string[] = [];
  t.onLine((l) => lines.push(l));

  const child = children[0]!;
  // Arrives complete, in one chunk, newline included.
  child.stdout.emit("data", `${"a".repeat(4096)}\n`);
  // A well-formed frame after it must still be delivered.
  child.stdout.emit("data", '{"ok":1}\n');

  assert.deepEqual(lines, ['{"ok":1}']);
});
