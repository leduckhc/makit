import { test } from "node:test";
import assert from "node:assert/strict";
import { PaneBridge, type PaneReader } from "./bridge.js";

/** A fake reader with a mutable current screen; records input/keys. */
function fakeReader(initial = "") {
  return {
    current: initial,
    texts: [] as string[],
    keysSent: [] as string[][],
    async read() {
      return this.current;
    },
    async sendText(_t: string, text: string) {
      this.texts.push(text);
    },
    async sendKeys(_t: string, keys: string[]) {
      this.keysSent.push(keys);
    },
  } satisfies PaneReader & { current: string; texts: string[]; keysSent: string[][] };
}

/** Let attach()'s fire-and-forget initial pollOnce settle. */
const flush = () => new Promise((r) => setImmediate(r));

test("emits an initial frame, then only when the screen changes", async () => {
  const reader = fakeReader("A");
  const frames: string[] = [];
  const b = new PaneBridge(reader, (_t, data) => frames.push(data), 10_000);
  b.attach("p1"); // immediate poll → "A"
  await flush();
  await b.pollOnce("p1"); // still "A" → no emit
  reader.current = "B";
  await b.pollOnce("p1"); // changed → emit
  b.detach("p1");
  assert.deepEqual(frames, ["A", "B"]);
});

test("ref-counts pollers: last detach stops mirroring", async () => {
  const reader = fakeReader("X");
  const frames: string[] = [];
  const b = new PaneBridge(reader, (_t, d) => frames.push(d), 10_000);
  b.attach("p1");
  await flush();
  b.attach("p1"); // 2nd subscriber shares the poller
  b.detach("p1"); // still one ref
  reader.current = "Y";
  await b.pollOnce("p1"); // alive → emits "Y"
  b.detach("p1"); // last ref → stops
  reader.current = "Z";
  await b.pollOnce("p1"); // no state → no-op
  assert.deepEqual(frames, ["X", "Y"]);
});

test("input and keys are forwarded to the reader", async () => {
  const reader = fakeReader();
  const b = new PaneBridge(reader, () => {}, 10_000);
  await b.input("p1", "hello");
  await b.keys("p1", ["Enter"]);
  assert.deepEqual(reader.texts, ["hello"]);
  assert.deepEqual(reader.keysSent, [["Enter"]]);
});

test("a reader error during poll is swallowed (no frame, no throw)", async () => {
  const reader: PaneReader = {
    read: async () => {
      throw new Error("herdr busy");
    },
    sendText: async () => {},
    sendKeys: async () => {},
  };
  const frames: string[] = [];
  const b = new PaneBridge(reader, (_t, d) => frames.push(d), 10_000);
  b.attach("p1");
  await flush();
  await b.pollOnce("p1");
  b.detach("p1");
  assert.equal(frames.length, 0);
});
