/**
 * makit — SPEC-doc-preview D10 rev 2: a publish must survive a concurrent idle release.
 *
 * The doc listener binds lazily and is released once no grant remains. The
 * release trigger fires from `DocsService.grants()` and `DocsService.unpublish()`
 * — that is, from a DIFFERENT client command than the publish it can interrupt.
 *
 * `publishDoc` reads the origin and mints the grant in two steps. A release that
 * lands between them counts zero live grants (the grant does not exist yet),
 * closes the port, and the publish then hands back a URL naming a closed socket.
 *
 * Nothing repairs that URL. The release path only ever closes, and the next
 * publish binds a FRESH ephemeral port, so the grant stays dead for its whole
 * TTL while the app reports a successful share.
 *
 * One person reaches this: publishing doc A while unpublishing doc B revokes a
 * grant (which triggers a release) and mints one at the same time.
 */

import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { DocGrantStore, type MintInput } from "./grants.js";
import { DocListener } from "./listener.js";
import { attachDocNotFound, attachDocRoute } from "./route.js";
import { publishDoc } from "./publish.js";
import type { DocGrantDTO } from "../protocol.js";

/** A worktree holding one publishable document. */
function repoWithDoc(): string {
  // realpath: on macOS `$TMPDIR` is a symlink into `/private/var`, and the D2
  // resolve compares realpaths.
  const root = realpathSync(mkdtempSync(join(tmpdir(), "makit-docrace-")));
  writeFileSync(join(root, "spec.md"), "# Spec\n");
  return root;
}

/**
 * A grant store that runs `onMint` in the exact window the race needs: after
 * the publish holds the origin, before the grant exists. It stands in for a
 * `docs.grants` read or a `docs.unpublish` arriving from another command.
 */
class ReleasingStore extends DocGrantStore {
  private readonly onMint: () => void;

  constructor(onMint: () => void) {
    super();
    this.onMint = onMint;
  }

  override mint(input: MintInput): DocGrantDTO {
    this.onMint();
    return super.mint(input);
  }
}

/** A store whose mint fails, to prove a lease releases the port it took. */
class FailingStore extends DocGrantStore {
  private readonly onMint: () => void;

  constructor(onMint: () => void) {
    super();
    this.onMint = onMint;
  }

  override mint(): DocGrantDTO {
    this.onMint();
    throw new Error("mint refused");
  }
}

function docListener(grants: DocGrantStore): DocListener {
  return new DocListener({
    bindHost: "127.0.0.1",
    liveGrants: () => grants.list().length,
    attach: (server) => {
      attachDocRoute(server, { grants });
      attachDocNotFound(server);
    },
  });
}

/** Poll until `ok()`, so an async release is observed without a fixed sleep. */
async function waitFor(ok: () => boolean, what: string): Promise<void> {
  const deadline = Date.now() + 2_000;
  while (Date.now() < deadline) {
    if (ok()) return;
    await new Promise((r) => setTimeout(r, 10));
  }
  assert.fail(`timed out waiting for ${what}`);
}

test("an idle release inside the publish window must not orphan the grant", async () => {
  const root = repoWithDoc();
  // `release` is fire-and-forget in `server.ts` (`void docListener.releaseIfIdle()`),
  // so keep the promise and settle it the way production would.
  let release: Promise<void> | undefined;
  const grants = new ReleasingStore(() => {
    release = listener.releaseIfIdle();
  });
  const listener = docListener(grants);

  try {
    const result = await publishDoc(
      { worktreePath: root, relPath: "spec.md" },
      { grants, withReach: (use) => listener.withOrigin(use) },
    );
    await release;

    assert.ok(result.ok, "the publish itself must succeed");
    assert.equal(
      listener.isListening,
      true,
      "the listener the grant names must still be bound",
    );

    // The real proof: the URL the user is handed actually answers. `connection:
    // close` keeps no pooled socket behind, so the cleanup below is instant.
    const answer = await fetch(result.grant.url, {
      headers: { connection: "close" },
    }).catch((err: Error) => err);
    assert.ok(
      answer instanceof Response,
      `the published URL must answer, got ${String(answer)}`,
    );
    assert.equal(answer.status, 200, "a published doc must serve, not 404");
    await answer.text();
  } finally {
    await listener.close();
  }
});

test("a lease that ends without a grant releases the port it took", async () => {
  const root = repoWithDoc();
  let release: Promise<void> | undefined;
  const grants = new FailingStore(() => {
    release = listener.releaseIfIdle();
  });
  const listener = docListener(grants);

  try {
    await assert.rejects(
      () =>
        publishDoc(
          { worktreePath: root, relPath: "spec.md" },
          { grants, withReach: (use) => listener.withOrigin(use) },
        ),
      /mint refused/,
      "a mint failure is not a reach failure — it must not be relabelled",
    );
    await release;

    // The release was skipped while the lease was held. Ending the lease must
    // re-check, or the port stays bound with nothing published.
    await waitFor(() => !listener.isListening, "the port to be released");
  } finally {
    await listener.close();
  }
});
