/**
 * Tests for the CLI credential fixture in `cli_home.ts`.
 *
 * The fixture exists so a CLI test authenticates with a bearer the test owns
 * ("CACHED"), against a stub server that accepts only that bearer.
 * `resolveBearer` reads `MAKIT_CLI_TOKEN` **before** the cached `cli.json`
 * (D2/D3 order), so an ambient token in the environment outranks the fixture.
 *
 * That is not hypothetical. A makit-spawned agent session exports
 * `MAKIT_CLI_TOKEN`, so an agent that runs `pnpm test` from inside makit made
 * 183 tests across 14 files fail with `[makit] unknown device`. The suite was
 * green in CI, which has no such token, and green for a human in a plain shell.
 * The harness isolated `MAKIT_HOME` and forgot the token beside it.
 *
 * So the fixture must hide the ambient token for the duration of the test, and
 * put it back afterwards.
 */
import { test } from "node:test";
import assert from "node:assert/strict";

import { withCliHome } from "./cli_home.js";
import { resolveBearer } from "../../src/cli/client.js";

/** A control seam that fails the test if `cli.grant` is reached at all. */
const noControl = {
  request: () => {
    throw new Error("resolveBearer must read the cached cli.json, not mint a bearer");
  },
};

test("withCliHome hides an ambient MAKIT_CLI_TOKEN, so the fixture bearer wins", async () => {
  const prev = process.env.MAKIT_CLI_TOKEN;
  process.env.MAKIT_CLI_TOKEN = "AMBIENT-AGENT-TOKEN";
  try {
    let bearer = "";
    await withCliHome(async () => {
      bearer = await resolveBearer(noControl);
    });
    assert.equal(bearer, "CACHED");
  } finally {
    if (prev === undefined) delete process.env.MAKIT_CLI_TOKEN;
    else process.env.MAKIT_CLI_TOKEN = prev;
  }
});

test("withCliHome restores the ambient MAKIT_CLI_TOKEN, even when the body throws", async () => {
  const prev = process.env.MAKIT_CLI_TOKEN;
  process.env.MAKIT_CLI_TOKEN = "AMBIENT-AGENT-TOKEN";
  try {
    await assert.rejects(
      withCliHome(async () => {
        throw new Error("boom");
      }),
      /boom/,
    );
    assert.equal(process.env.MAKIT_CLI_TOKEN, "AMBIENT-AGENT-TOKEN");
  } finally {
    if (prev === undefined) delete process.env.MAKIT_CLI_TOKEN;
    else process.env.MAKIT_CLI_TOKEN = prev;
  }
});

test("withCliHome leaves MAKIT_CLI_TOKEN absent when it was absent", async () => {
  const prev = process.env.MAKIT_CLI_TOKEN;
  delete process.env.MAKIT_CLI_TOKEN;
  try {
    await withCliHome(async () => {
      assert.equal(process.env.MAKIT_CLI_TOKEN, undefined);
    });
    assert.equal(process.env.MAKIT_CLI_TOKEN, undefined);
    assert.equal("MAKIT_CLI_TOKEN" in process.env, false);
  } finally {
    if (prev !== undefined) process.env.MAKIT_CLI_TOKEN = prev;
  }
});
