import { test } from "node:test";
import assert from "node:assert/strict";

import { CommandRouter } from "../../src/ws/command_router.js";
import type { WsClient, OutgoingFrame } from "../../src/ws/client.js";
import type { Envelope } from "../../src/protocol.js";
import { WireErrorCode } from "../../src/protocol/codec.js";

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

test("unknown cmd kind replies with bad_request and never throws", async () => {
  const router = new CommandRouter();
  const client = fakeClient();

  await assert.doesNotReject(router.dispatch(client, cmd("does.not.exist")));

  const err = client.sent.find((f) => f.t === "err");
  assert.ok(err);
  assert.equal(err!.code, WireErrorCode.BadRequest);
  assert.match(String(err!.message), /unknown cmd/);
});

test("a registered handler is dispatched and can ack", async () => {
  const router = new CommandRouter();
  let seen: string | undefined;
  router.register("send.message", (ctx) => {
    seen = String(ctx.env.text ?? "");
    ctx.ack();
  });
  const client = fakeClient();

  await router.dispatch(client, cmd("send.message", { text: "hi there" }));

  assert.equal(seen, "hi there");
  assert.ok(client.sent.find((f) => f.t === "ack" && f.id === "c1"));
});

test("a malformed send.message yields a typed bad_request err", async () => {
  const router = new CommandRouter();
  // Representative of the real handler's field validation: text must be a string.
  router.register("send.message", (ctx) => {
    if (typeof ctx.env.text !== "string") {
      ctx.err(WireErrorCode.BadRequest, "send.message requires a string `text`");
      return;
    }
    ctx.ack();
  });
  const client = fakeClient();

  await router.dispatch(client, cmd("send.message", { text: 42 }));

  const err = client.sent.find((f) => f.t === "err");
  assert.ok(err);
  assert.equal(err!.code, WireErrorCode.BadRequest);
  assert.equal(client.sent.find((f) => f.t === "ack"), undefined);
});

test("a throwing handler is caught and reported, never propagated", async () => {
  const router = new CommandRouter();
  router.register("boom", () => {
    throw new Error("kaboom");
  });
  const client = fakeClient();

  await assert.doesNotReject(router.dispatch(client, cmd("boom")));

  const err = client.sent.find((f) => f.t === "err");
  assert.ok(err);
  assert.match(String(err!.message), /kaboom/);
});

test("register is chainable and returns the router", () => {
  const router = new CommandRouter();
  const returned = router.register("a", () => {}).register("b", () => {});
  assert.equal(returned, router);
});
