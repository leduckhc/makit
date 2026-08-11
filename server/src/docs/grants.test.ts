import assert from "node:assert/strict";
import { test } from "node:test";

import {
  DocGrantStore,
  DOC_GRANT_TTL_MS,
  DOC_GRANT_IDLE_MS,
  MAX_LIVE_GRANTS,
} from "./grants.js";

function mint(store: DocGrantStore, relPath = "mockups/board.html") {
  return store.mint({
    worktreePath: "/wt",
    relPath,
    reach: "tailnet",
    buildUrl: (grantId) => `https://host.ts.net/docs/${grantId}/${relPath}`,
  });
}

test("mint returns a 32-byte (64 hex char) unguessable grantId", () => {
  const store = new DocGrantStore();
  const a = mint(store);
  const b = mint(store);
  assert.match(a.grantId, /^[0-9a-f]{64}$/);
  assert.notEqual(a.grantId, b.grantId);
});

test("mint builds the url from the freshly-minted grantId and sets expiry", () => {
  let clock = 1_000;
  const store = new DocGrantStore({ now: () => clock });
  const g = mint(store);
  assert.equal(g.url, `https://host.ts.net/docs/${g.grantId}/mockups/board.html`);
  assert.equal(g.reach, "tailnet");
  assert.equal(g.expiresAt, 1_000 + DOC_GRANT_TTL_MS);
});

test("resolve returns the grant for a known id and touches its idle clock", () => {
  let clock = 0;
  const store = new DocGrantStore({ now: () => clock });
  const g = mint(store);
  clock = DOC_GRANT_IDLE_MS - 1;
  const got = store.resolve(g.grantId);
  assert.equal(got?.grantId, g.grantId);
  // The touch reset the idle window, so it survives another near-idle span.
  clock += DOC_GRANT_IDLE_MS - 1;
  assert.ok(store.resolve(g.grantId), "the idle clock was not reset on access");
});

test("resolve of an unknown id is undefined (the route turns this into a 404)", () => {
  const store = new DocGrantStore();
  assert.equal(store.resolve("deadbeef"), undefined);
});

test("a grant past its hard TTL is reaped even if recently touched", () => {
  let clock = 0;
  const store = new DocGrantStore({ now: () => clock });
  const g = mint(store);
  // Keep touching just inside the idle window so idle never reaps it — then
  // cross the hard TTL, which must win over the touch.
  for (clock = DOC_GRANT_IDLE_MS - 1; clock < DOC_GRANT_TTL_MS; clock += DOC_GRANT_IDLE_MS - 1) {
    assert.ok(store.resolve(g.grantId), `alive at ${clock}`);
  }
  clock = DOC_GRANT_TTL_MS + 1;
  assert.equal(store.resolve(g.grantId), undefined, "hard TTL must win over touch");
});

test("an idle grant is reaped before its TTL", () => {
  let clock = 0;
  const store = new DocGrantStore({ now: () => clock });
  const g = mint(store);
  clock = DOC_GRANT_IDLE_MS + 1; // idle, but well within the 30-min TTL
  assert.equal(store.resolve(g.grantId), undefined);
});

test("revoke drops the grant; a second revoke reports it was already gone", () => {
  const store = new DocGrantStore();
  const g = mint(store);
  assert.equal(store.revoke(g.grantId), true);
  assert.equal(store.resolve(g.grantId), undefined);
  assert.equal(store.revoke(g.grantId), false);
});

test("list enumerates the live grants as DTOs and omits reaped ones", () => {
  let clock = 0;
  const store = new DocGrantStore({ now: () => clock });
  const a = mint(store, "a.md");
  mint(store, "b.md");
  assert.equal(store.list().length, 2);
  clock = DOC_GRANT_IDLE_MS - 1;
  store.resolve(a.grantId); // touch a just inside its idle window so it survives
  clock = DOC_GRANT_IDLE_MS + 1; // b (never touched) is now idle-reaped; a is not
  const live = store.list();
  assert.equal(live.length, 1);
  assert.equal(live[0]!.relPath, "a.md");
  // A DTO carries no internal clocks.
  assert.deepEqual(Object.keys(live[0]!).sort(), [
    "expiresAt",
    "grantId",
    "reach",
    "relPath",
    "url",
    "worktreePath",
  ]);
});

// Reaping is lazy (inside resolve/list), so between reads a publish loop could
// grow the map without bound — each entry pinning a path and keeping the doc
// listener alive. mint() now reaps first, then caps.
test("the live grant set is capped, evicting the least recently used", () => {
  let clock = 1_000;
  const store = new DocGrantStore({ now: () => clock });
  const mint = (n: number) =>
    store.mint({
      worktreePath: "/wt",
      relPath: `mockups/${n}.html`,
      reach: "tailnet",
      buildUrl: (id) => `http://h/docs/${id}/mockups/${n}.html`,
    });

  const first = mint(0);
  for (let i = 1; i < MAX_LIVE_GRANTS; i++) {
    clock += 1; // each subsequent grant is more recently seen than `first`
    mint(i);
  }
  assert.equal(store.list().length, MAX_LIVE_GRANTS);

  clock += 1;
  mint(9999);
  assert.equal(store.list().length, MAX_LIVE_GRANTS, "the cap holds");
  assert.equal(
    store.resolve(first.grantId),
    undefined,
    "the least recently seen grant is the one evicted",
  );
});
