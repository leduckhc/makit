// How much one event costs the write path, on a real file.
//
//   node --import tsx tool/write_bench.ts
//
// Arms: an event insert at `synchronous=FULL` (the WAL default this project
// shipped with, one fsync per commit) against `NORMAL` (what the store sets
// now), then the 17-column session upsert `Session.record` used to run per
// token, then `reserveSeq` — what a streamed delta costs since it stopped
// being a row (see src/stream_digest.ts).
//
// Results (M-series, APFS SSD, 20000 iterations each):
//
//   insert @FULL   : 55.6 us
//   insert @NORMAL : 11.8 us     (4.7x)
//   session upsert :  5.6 us
//   reserveSeq     :  0.0 us
//
// Reading: a token used to cost an insert plus an upsert plus two fsyncs, and
// now costs a counter increment. Throwaway bench, not referenced by the server.
import { SqliteEventStore } from "../src/storage/sqlite_event_store.js";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const dir = mkdtempSync(join(tmpdir(), "makit-write-bench-"));
const store = new SqliteEventStore(join(dir, "bench.db"));
store.saveSession({ id: "s1", projectId: "p", agent: "pi", title: "t", status: "running",
  policy: "ask-on-risky", createdAt: 1, lastActivityAt: 1, lastPreview: "" });

const N = 20000;
const payload = { msgId: "m1", chunk: "lorem ipsum dolor sit amet consectetur a" };

// Arm 1: the default this project shipped with — WAL at synchronous=FULL, i.e.
// one fsync per commit.
store.pragma("synchronous = FULL");
let t = performance.now();
for (let i = 0; i < N; i++) store.append("s1", { ts: i, kind: "agent.message.delta", payload });
const fullMs = performance.now() - t;

// Arm 2: WAL at NORMAL, what the store sets now.
store.pragma("synchronous = NORMAL");
t = performance.now();
for (let i = 0; i < N; i++) store.append("s1", { ts: i, kind: "agent.message.delta", payload });
const insertMs = performance.now() - t;

t = performance.now();
for (let i = 0; i < N; i++) {
  store.saveSession({ id: "s1", projectId: "p", agent: "pi", title: "t", status: "running",
    policy: "ask-on-risky", createdAt: 1, lastActivityAt: i, lastPreview: "x" });
}
const metaMs = performance.now() - t;

t = performance.now();
for (let i = 0; i < N; i++) store.reserveSeq("s1");
const reserveMs = performance.now() - t;

console.log(`synchronous=${store.pragma("synchronous")} journal=${store.pragma("journal_mode")}`);
console.log(`insert @FULL  : ${(fullMs / N * 1000).toFixed(1)} us each (${fullMs.toFixed(0)} ms for ${N})`);
console.log(`insert @NORMAL: ${(insertMs / N * 1000).toFixed(1)} us each (${insertMs.toFixed(0)} ms for ${N})`);
console.log(`session upsert: ${(metaMs / N * 1000).toFixed(1)} us each (${metaMs.toFixed(0)} ms for ${N})`);
console.log(`reserveSeq   : ${(reserveMs / N * 1000).toFixed(1)} us each — what a delta costs now`);
store.close();
rmSync(dir, { recursive: true, force: true });
