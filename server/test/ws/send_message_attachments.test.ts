/**
 * `send.message` attachment validation (SPEC-33 T3).
 *
 * Drives the **real** session command registrar through the real
 * {@link CommandRouter} with a minimal fake manager, mirroring
 * `agents_catalog.test.ts`. The rules under test are the ones that decide
 * whether an image the user attached actually reaches the agent:
 *
 * - a `mediaId` the store cannot resolve is an **error**, never a silent drop
 *   (the alternative turns "look at this screenshot" into a bare text prompt);
 * - malformed entries *are* dropped, matching `parseConfigPicks`;
 * - text may be empty when an attachment resolved (an image alone is a turn);
 * - the resolved descriptors reach `sendUserMessage`, not the raw wire ids.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { CommandRouter } from "../../src/ws/command_router.js";
import { register } from "../../src/ws/commands/session.js";
import type { CommandDeps } from "../../src/ws/commands/deps.js";
import type { WsClient, OutgoingFrame } from "../../src/ws/client.js";
import type { Envelope } from "../../src/protocol.js";
import { WireErrorCode } from "../../src/protocol/codec.js";
import { MediaStore, type MediaAttachment } from "../../src/media/store.js";

interface FakeClient extends WsClient {
  sent: OutgoingFrame[];
}

function fakeClient(): FakeClient {
  const sent: OutgoingFrame[] = [];
  return {
    sent,
    authed: true,
    subscribed: new Set<string>(),
    send: (frame) => sent.push(frame),
    close: () => {},
  };
}

function cmd(kind: string, fields: Partial<Envelope> = {}): Envelope {
  return { v: 1, t: "cmd", id: "c1", kind, ...fields } as Envelope;
}

interface SentTurn {
  text: string;
  attachments?: MediaAttachment[];
}

function harness() {
  const dir = mkdtempSync(join(tmpdir(), "makit-send-attach-"));
  const media = new MediaStore({ dir });
  const turns: SentTurn[] = [];
  const session = {
    pending: false,
    sendUserMessage: async (text: string, attachments?: MediaAttachment[]) => {
      turns.push({ text, attachments });
    },
  };
  const router = new CommandRouter();
  const deps = {
    manager: {
      getSession: (sid: string) => (sid === "s1" ? session : undefined),
    } as unknown as CommandDeps["manager"],
    gateway: {} as CommandDeps["gateway"],
    budgetWatch: {} as CommandDeps["budgetWatch"],
    media,
    broadcastSnapshots: () => {},
    broadcastReposSnapshot: async () => {},
    broadcastBudget: () => {},
    askDevice: async () => ({}) as Envelope,
  } satisfies CommandDeps;
  register(router, deps);
  const client = fakeClient();
  const send = (fields: Partial<Envelope>) =>
    router.dispatch(client, cmd("send.message", { sessionId: "s1", ...fields }));
  const errOf = () => client.sent.find((f) => f.t === "err");
  return { media, turns, router, client, send, errOf, session };
}

const png = Buffer.from("fake-png-bytes");

test("a resolvable attachment reaches the adapter as a full descriptor", async () => {
  const h = harness();
  const d = h.media.put(png, "image/png");

  await h.send({ text: "what is wrong here?", attachments: [{ mediaId: d.mediaId, name: "shot.png" }] });

  assert.equal(h.errOf(), undefined);
  assert.equal(h.turns.length, 1);
  assert.equal(h.turns[0]!.text, "what is wrong here?");
  // The wire carries only an id + hint; the adapter must receive mime and size
  // too, which only the store knows.
  assert.deepEqual(h.turns[0]!.attachments, [
    { mediaId: d.mediaId, mime: "image/png", sizeBytes: png.length, name: "shot.png" },
  ]);
});

test("an image with no text is a valid turn", async () => {
  const h = harness();
  const d = h.media.put(png, "image/png");

  await h.send({ text: "", attachments: [{ mediaId: d.mediaId }] });

  assert.equal(h.errOf(), undefined);
  assert.equal(h.turns.length, 1);
  assert.equal(h.turns[0]!.text, "");
  assert.equal(h.turns[0]!.attachments?.length, 1);
});

test("empty text with NO attachments keeps working exactly as before", async () => {
  // Regression guard: the empty-text allowance must not become a new rejection.
  const h = harness();
  await h.send({ text: "" });
  assert.equal(h.errOf(), undefined);
  assert.deepEqual(h.turns, [{ text: "", attachments: undefined }]);
});

test("a mediaId the store cannot resolve is bad_request, not a silent drop", async () => {
  const h = harness();
  const missing = "a".repeat(64); // well-formed, never stored

  await h.send({ text: "look", attachments: [{ mediaId: missing }] });

  const err = h.errOf();
  assert.ok(err, "expected an error frame");
  assert.equal(err!.code, WireErrorCode.BadRequest);
  assert.match(String(err!.message), /attachment/i);
  assert.equal(h.turns.length, 0, "the turn must not be sent without the image");
});

test("malformed attachment entries are dropped, like configOption picks", async () => {
  const h = harness();
  const d = h.media.put(png, "image/png");

  await h.send({
    text: "hi",
    attachments: [
      null,
      "nope",
      {},
      { mediaId: 42 },
      { mediaId: "" },
      { mediaId: "not-a-sha" }, // wrong shape → dropped, not looked up
      { mediaId: d.mediaId, name: 7 }, // bad hint type → kept, hint dropped
    ],
  });

  assert.equal(h.errOf(), undefined);
  assert.equal(h.turns.length, 1);
  assert.deepEqual(h.turns[0]!.attachments, [
    { mediaId: d.mediaId, mime: "image/png", sizeBytes: png.length },
  ]);
});

test("a non-array `attachments` is ignored, not an error", async () => {
  const h = harness();
  await h.send({ text: "hi", attachments: "shot.png" });
  assert.equal(h.errOf(), undefined);
  assert.deepEqual(h.turns, [{ text: "hi", attachments: undefined }]);
});

test("more than 8 attachments is bad_request", async () => {
  const h = harness();
  const ids = Array.from({ length: 9 }, (_, i) => ({
    mediaId: h.media.put(Buffer.from(`png-${i}`), "image/png").mediaId,
  }));

  await h.send({ text: "many", attachments: ids });

  const err = h.errOf();
  assert.ok(err);
  assert.equal(err!.code, WireErrorCode.BadRequest);
  assert.equal(h.turns.length, 0);
});

test("text is still required to be a string", async () => {
  const h = harness();
  await h.send({ text: 42 });
  const err = h.errOf();
  assert.ok(err);
  assert.equal(err!.code, WireErrorCode.BadRequest);
  assert.equal(h.turns.length, 0);
});

test("a pending session promoted by an image-only turn gets a usable label", async () => {
  // Promotion names the branch/worktree from the first message. An image-only
  // turn has no text, so the manager must be handed a fallback rather than "".
  const dir = mkdtempSync(join(tmpdir(), "makit-send-attach-pending-"));
  const media = new MediaStore({ dir });
  const d = media.put(png, "image/png");
  const turns: SentTurn[] = [];
  const labels: string[] = [];
  const session = {
    pending: true,
    sendUserMessage: async (text: string, attachments?: MediaAttachment[]) => {
      turns.push({ text, attachments });
    },
  };
  const router = new CommandRouter();
  register(router, {
    manager: {
      getSession: () => session,
      promotePendingSession: async (_s: unknown, label: string) => {
        labels.push(label);
        return true;
      },
    } as unknown as CommandDeps["manager"],
    gateway: {} as CommandDeps["gateway"],
    budgetWatch: {} as CommandDeps["budgetWatch"],
    media,
    broadcastSnapshots: () => {},
    broadcastReposSnapshot: async () => {},
    broadcastBudget: () => {},
    askDevice: async () => ({}) as Envelope,
  } satisfies CommandDeps);

  await router.dispatch(
    fakeClient(),
    cmd("send.message", { sessionId: "s1", text: "", attachments: [{ mediaId: d.mediaId }] }),
  );

  assert.equal(labels.length, 1);
  assert.notEqual(labels[0], "", "an empty branch label would be unusable");
  assert.equal(turns.length, 1);
});
