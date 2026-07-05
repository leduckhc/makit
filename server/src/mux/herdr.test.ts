import { test } from "node:test";
import assert from "node:assert/strict";
import { MuxError } from "./adapter.js";
import {
  HerdrAdapter,
  parsePaneList,
  parseSplitPaneId,
  type ExecFn,
} from "./herdr.js";

function splitJson(paneId: string): string {
  return JSON.stringify({
    id: "cli:pane:split",
    result: { type: "pane_info", pane: { pane_id: paneId } },
  });
}

function paneListJson(ids: string[]): string {
  return JSON.stringify({
    id: "cli:pane:list",
    result: {
      type: "pane_list",
      panes: ids.map((pane_id) => ({ pane_id })),
    },
  });
}

function recordingExec(
  responses: Record<string, string | Error> = {},
): ExecFn & { calls: Array<{ cmd: string; args: string[] }> } {
  const calls: Array<{ cmd: string; args: string[] }> = [];
  const fn: ExecFn = async (cmd, args) => {
    calls.push({ cmd, args });
    const key = `${cmd} ${args.join(" ")}`;
    const hit = responses[key];
    if (hit instanceof Error) throw hit;
    if (typeof hit === "string") return { stdout: hit, stderr: "" };
    return { stdout: "", stderr: "" };
  };
  return Object.assign(fn, { calls });
}

test("parseSplitPaneId extracts pane_id from split JSON", () => {
  assert.equal(parseSplitPaneId(splitJson("w7:pS")), "w7:pS");
});

test("parseSplitPaneId throws MuxError on bad JSON", () => {
  assert.throws(() => parseSplitPaneId("nope"), MuxError);
});

test("parseSplitPaneId throws MuxError when pane_id missing", () => {
  assert.throws(
    () => parseSplitPaneId(JSON.stringify({ result: { pane: {} } })),
    MuxError,
  );
});

test("parsePaneList returns pane ids", () => {
  assert.deepEqual(parsePaneList(paneListJson(["w7:p1", "w7:p2"])), [
    "w7:p1",
    "w7:p2",
  ]);
});

test("parsePaneList returns [] on garbage", () => {
  assert.deepEqual(parsePaneList("bad"), []);
});

test("isAvailable true when pane list succeeds", async () => {
  const exec = recordingExec({
    "herdr pane list": paneListJson([]),
  });
  const adapter = new HerdrAdapter({ exec, anchor: "pino" });
  assert.equal(await adapter.isAvailable(), true);
});

test("isAvailable false when herdr missing", async () => {
  const failing: ExecFn = async () => {
    throw Object.assign(new Error("ENOENT"), { code: "ENOENT" });
  };
  const adapter = new HerdrAdapter({ exec: failing, anchor: "pino" });
  assert.equal(await adapter.isAvailable(), false);
});

test("spawnPane splits unfocused, runs command, sets label", async () => {
  const exec = recordingExec({
    "herdr pane split pino --direction down --cwd /proj --no-focus":
      splitJson("w7:pS"),
    "herdr pane run w7:pS echo hi": "",
    "herdr pane rename w7:pS pino: test": "",
  });
  const adapter = new HerdrAdapter({ exec, anchor: "pino" });
  const handle = await adapter.spawnPane({
    cwd: "/proj",
    command: "echo hi",
    label: "pino: test",
  });

  assert.equal(handle.mux, "herdr");
  assert.equal(handle.paneId, "w7:pS");
  assert.deepEqual(exec.calls[0], {
    cmd: "herdr",
    args: ["pane", "split", "pino", "--direction", "down", "--cwd", "/proj", "--no-focus"],
  });
  assert.deepEqual(exec.calls[1], {
    cmd: "herdr",
    args: ["pane", "run", "w7:pS", "echo hi"],
  });
  assert.deepEqual(exec.calls[2], {
    cmd: "herdr",
    args: ["pane", "rename", "w7:pS", "pino: test"],
  });
});

test("spawnPane omits --no-focus when focus true", async () => {
  const exec = recordingExec({
    "herdr pane split pino --direction down --cwd /proj": splitJson("w7:pX"),
    "herdr pane run w7:pX cmd": "",
  });
  const adapter = new HerdrAdapter({ exec, anchor: "pino" });
  await adapter.spawnPane({ cwd: "/proj", command: "cmd", focus: true });
  assert.ok(!exec.calls[0]!.args.includes("--no-focus"));
});

test("spawnPane throws MuxError when split fails", async () => {
  const exec: ExecFn = async () => {
    throw new Error("split failed");
  };
  const adapter = new HerdrAdapter({ exec, anchor: "pino" });
  await assert.rejects(
    () => adapter.spawnPane({ cwd: "/proj", command: "echo hi" }),
    (e: unknown) => e instanceof MuxError && e.mux === "herdr",
  );
});

test("spawnPane closes orphan pane when run fails", async () => {
  const calls: Array<{ cmd: string; args: string[] }> = [];
  const exec: ExecFn = async (cmd, args) => {
    calls.push({ cmd, args });
    const key = `${cmd} ${args.join(" ")}`;
    if (key.includes("pane split")) return { stdout: splitJson("w7:pS"), stderr: "" };
    if (key.includes("pane run")) throw new Error("run failed");
    return { stdout: "", stderr: "" };
  };
  const adapter = new HerdrAdapter({ exec, anchor: "pino" });
  await assert.rejects(
    () => adapter.spawnPane({ cwd: "/proj", command: "echo hi" }),
    (e: unknown) => e instanceof MuxError && e.mux === "herdr",
  );
  assert.deepEqual(calls[2], {
    cmd: "herdr",
    args: ["pane", "close", "w7:pS"],
  });
});

test("spawnPane skips rename when label omitted", async () => {
  const exec = recordingExec({
    "herdr pane split pino --direction down --cwd /proj --no-focus":
      splitJson("w7:pS"),
    "herdr pane run w7:pS echo hi": "",
  });
  const adapter = new HerdrAdapter({ exec, anchor: "pino" });
  await adapter.spawnPane({ cwd: "/proj", command: "echo hi" });
  assert.equal(
    exec.calls.filter((c) => c.args[1] === "rename").length,
    0,
  );
});

test("closePane invokes herdr pane close", async () => {
  const exec = recordingExec();
  const adapter = new HerdrAdapter({ exec, anchor: "pino" });
  await adapter.closePane({ mux: "herdr", paneId: "w7:pS" });
  assert.deepEqual(exec.calls[0], {
    cmd: "herdr",
    args: ["pane", "close", "w7:pS"],
  });
});

test("closePane is idempotent", async () => {
  const exec = recordingExec();
  const failingClose: ExecFn = async (cmd, args) => {
    exec.calls.push({ cmd, args });
    if (args[1] === "close") throw new Error("already gone");
    return { stdout: "", stderr: "" };
  };
  const adapter = new HerdrAdapter({ exec: failingClose, anchor: "pino" });
  const handle = { mux: "herdr", paneId: "w7:pS" };
  await adapter.closePane(handle);
  await adapter.closePane(handle);
  assert.equal(exec.calls.filter((c) => c.args[1] === "close").length, 2);
});

test("spawn close lifecycle: exists then gone after close", async () => {
  let listed = ["w7:pS"];
  const exec: ExecFn = async (_cmd, args) => {
    if (args[1] === "split") return { stdout: splitJson("w7:pS"), stderr: "" };
    if (args[1] === "list") return { stdout: paneListJson(listed), stderr: "" };
    if (args[1] === "close") {
      listed = listed.filter((id) => id !== args[2]);
      return { stdout: "", stderr: "" };
    }
    return { stdout: "", stderr: "" };
  };
  const adapter = new HerdrAdapter({ exec, anchor: "pino" });
  const handle = await adapter.spawnPane({
    cwd: "/proj",
    command: "echo hi; sleep 30",
    label: "pino: test",
  });
  assert.equal(await adapter.paneExists(handle), true);
  await adapter.closePane(handle);
  await adapter.closePane(handle);
  assert.equal(await adapter.paneExists(handle), false);
});

test("paneExists checks pane list", async () => {
  const exec = recordingExec({
    "herdr pane list": paneListJson(["w7:p1"]),
  });
  const adapter = new HerdrAdapter({ exec, anchor: "pino" });
  assert.equal(await adapter.paneExists({ mux: "herdr", paneId: "w7:p1" }), true);
  assert.equal(await adapter.paneExists({ mux: "herdr", paneId: "w7:p9" }), false);
});
