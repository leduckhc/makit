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

test("dispose kills the child", () => {
  const { spawn, children } = fakeSpawn();
  const t = spawnLineProcess({ command: "x", cwd: "/tmp", label: "t", spawn });
  t.dispose();
  assert.equal(children[0]!.killed, true);
});
