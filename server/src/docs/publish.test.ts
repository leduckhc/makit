import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, mkdirSync, writeFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { DocGrantStore } from "./grants.js";
import { publishDoc } from "./publish.js";
import type { DocReach } from "./publish.js";

function fixture(): string {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "makit-publish-")));
  mkdirSync(join(root, "mockups"), { recursive: true });
  writeFileSync(join(root, "mockups", "board.html"), "<title>Board</title>");
  return root;
}

const tailnet = async (): Promise<DocReach> => ({ origin: "https://host.ts.net", reach: "tailnet" });
// `lan` is an INJECTED-ONLY reach: per D15 rev 2 `DocListener` never emits it in
// P1 (the tailnet is the only publishable reach). It is retained in the DocReach
// union so the wire contract needs no change if LAN is ever reinstated behind an
// explicit opt-in; this fixture just proves `publishDoc` faithfully mints
// whatever verified reach it is handed.
const lan = async (): Promise<DocReach> => ({ origin: "http://192.168.1.9:8123", reach: "lan" });
const none = async (): Promise<DocReach | null> => null;

test("publishes a resolvable doc, minting a tailnet grant with the reachable url", async () => {
  const root = fixture();
  const grants = new DocGrantStore();
  const result = await publishDoc(
    { worktreePath: root, relPath: "mockups/board.html" },
    { grants, reach: tailnet },
  );
  assert.ok(result.ok);
  assert.equal(result.grant.reach, "tailnet");
  assert.equal(
    result.grant.url,
    `https://host.ts.net/docs/${result.grant.grantId}/mockups/board.html`,
  );
  // The grant is enumerable afterwards.
  assert.equal(grants.list().length, 1);
});

test("mints whatever verified reach it is handed, e.g. an injected lan origin (D15)", async () => {
  const root = fixture();
  const grants = new DocGrantStore();
  const result = await publishDoc(
    { worktreePath: root, relPath: "mockups/board.html" },
    { grants, reach: lan },
  );
  assert.ok(result.ok);
  assert.equal(result.grant.reach, "lan");
  assert.match(result.grant.url, /^http:\/\/192\.168\.1\.9:8123\/docs\//);
});

test("with no usable address, publishes NOTHING and states the reason (D15)", async () => {
  const root = fixture();
  const grants = new DocGrantStore();
  const result = await publishDoc(
    { worktreePath: root, relPath: "mockups/board.html" },
    { grants, reach: none },
  );
  assert.equal(result.ok, false);
  assert.ok(!result.ok && result.reason.length > 0);
  assert.equal(grants.list().length, 0, "no grant was minted for an unreachable publish");
});

// D15 rev 2 makes the tailnet the ONLY publishable reach and explicitly drops the
// LAN fallback, so `--lan` cannot make publishing work: it binds a 192.168/10.x
// host, which `tailnetAddressFromBindHost` rejects, and publish refuses again.
// Naming it as the remedy is the one thing D15 forbids — a refusal that lies.
test("the refusal states a remedy that can actually work, never --lan (D15 rev 2)", async () => {
  const root = fixture();
  const result = await publishDoc(
    { worktreePath: root, relPath: "mockups/board.html" },
    { grants: new DocGrantStore(), reach: none },
  );
  assert.equal(result.ok, false);
  const reason = result.ok ? "" : result.reason;
  assert.ok(
    !reason.includes("--lan"),
    `the LAN fallback is dropped, so the reason must not offer it: ${reason}`,
  );
  assert.match(reason, /Tailscale/, "the one remedy that works must be named");
});

test("refuses an unresolvable doc without minting a grant", async () => {
  const root = fixture();
  const grants = new DocGrantStore();
  const result = await publishDoc(
    { worktreePath: root, relPath: "../../etc/passwd" },
    { grants, reach: tailnet },
  );
  assert.equal(result.ok, false);
  assert.equal(grants.list().length, 0);
});

test("does not consult reach when the doc cannot be resolved", async () => {
  const root = fixture();
  const grants = new DocGrantStore();
  let reachCalls = 0;
  await publishDoc(
    { worktreePath: root, relPath: "does-not-exist.md" },
    {
      grants,
      reach: async () => {
        reachCalls++;
        return { origin: "https://host.ts.net", reach: "tailnet" };
      },
    },
  );
  assert.equal(reachCalls, 0, "an invalid doc must be refused before probing reachability");
});

// A published URL is copied, QR-encoded and opened in Safari, so it must be a
// VALID url. An unencoded space is malformed, and an unencoded "#" or "?" would
// truncate the path at the fragment/query — the route would then resolve a
// different relPath than the grant was minted for and answer 404, i.e. the
// publish button would silently produce a dead link for an ordinarily-named file.
test("publishDoc percent-encodes each path segment of the URL", async () => {
  const grants = new DocGrantStore();
  const relPath = "mockups/my notes #2 & draft.md";
  const res = await publishDoc(
    { worktreePath: "/repo", relPath },
    {
      grants,
      reach: async () => ({ origin: "http://100.1.1.1:8123", reach: "tailnet" }),
      resolveDoc: () => ({
        ok: true,
        absPath: `/repo/${relPath}`,
        relPath,
        kind: "md",
        bytes: 10,
        modifiedAt: 0,
      }),
    },
  );
  assert.equal(res.ok, true);
  const url = res.ok ? res.grant.url : "";

  assert.ok(!url.includes(" "), `url must not contain a raw space: ${url}`);
  assert.ok(!url.includes("#"), `url must not contain a raw '#': ${url}`);

  // The decoded path must round-trip back to exactly the granted relPath, which
  // is what the route compares against.
  const parsed = new URL(url);
  const prefix = parsed.pathname.split("/").slice(0, 3).join("/"); // "" + "docs" + grantId
  const decoded = decodeURIComponent(parsed.pathname.slice(prefix.length + 1));
  assert.equal(decoded, relPath);

  // Slashes stay slashes — encoding must be per segment, not over the whole path.
  assert.ok(parsed.pathname.includes("/mockups/"), `segments must stay separate: ${parsed.pathname}`);
});


// A reach probe can throw (a bind failure, a spawn error while asking Tailscale).
// Unwrapped, that escaped as an unhandled rejection through the command router
// instead of becoming the stated reason D15 requires.
test("a throwing reach probe becomes a stated reason, not an unhandled rejection", async () => {
  const root = fixture();
  const grants = new DocGrantStore();
  const result = await publishDoc(
    { worktreePath: root, relPath: "mockups/board.html" },
    {
      grants,
      reach: async () => {
        throw new Error("EADDRINUSE 100.64.0.1:7801");
      },
    },
  );
  assert.equal(result.ok, false);
  assert.match(result.ok ? "" : result.reason, /EADDRINUSE/);
  assert.equal(grants.list().length, 0, "nothing is shared when reach failed");
});
