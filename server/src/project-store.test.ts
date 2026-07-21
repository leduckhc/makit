import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import {
  loadProjects,
  saveProjects,
  browseDirectory,
} from "./project-store.js";

test("saveProjects / loadProjects round-trips id+path, dropping deleted dirs", () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-store-"));
  try {
    const file = join(dir, "nested", "projects.json");
    const existing = join(dir, "project");
    mkdirSync(existing);
    saveProjects(file, [
      { id: "id-a", path: existing },
      { id: "id-b", path: join(dir, "deleted-project") },
    ]);
    // The deleted dir is filtered on load; the surviving entry keeps its id.
    assert.deepEqual(loadProjects(file), [{ id: "id-a", path: existing }]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("loadProjects migrates the legacy path-only format, minting stable ids", () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-store-"));
  try {
    const file = join(dir, "projects.json");
    const existing = join(dir, "project");
    mkdirSync(existing);
    // Legacy shape: bare path strings, no ids.
    writeFileSync(file, JSON.stringify({ projects: [existing] }));
    const loaded = loadProjects(file);
    assert.equal(loaded.length, 1);
    assert.equal(loaded[0].path, existing);
    assert.ok(loaded[0].id.length > 0);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("loadProjects returns [] for a missing file", () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-store-"));
  try {
    assert.deepEqual(loadProjects(join(dir, "nope.json")), []);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("loadProjects returns [] for a malformed file", () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-store-"));
  try {
    const file = join(dir, "bad.json");
    writeFileSync(file, "{ not valid json ");
    assert.deepEqual(loadProjects(file), []);
    writeFileSync(file, JSON.stringify({ projects: "not-an-array" }));
    assert.deepEqual(loadProjects(file), []);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("browseDirectory lists dirs only, marks repos, skips hidden + files", () => {
  const root = mkdtempSync(join(tmpdir(), "makit-browse-"));
  try {
    mkdirSync(join(root, "alpha"));
    mkdirSync(join(root, "beta"));
    mkdirSync(join(root, "beta", ".git"));
    mkdirSync(join(root, ".hidden"));
    writeFileSync(join(root, "afile.txt"), "x");

    const result = browseDirectory(root);
    assert.equal(result.path, root);
    assert.equal(result.parent, dirname(root));

    const names = result.entries.map((e) => e.name);
    assert.deepEqual(names, ["alpha", "beta"]);

    const beta = result.entries.find((e) => e.name === "beta")!;
    assert.equal(beta.isRepo, true);
    assert.equal(beta.path, join(root, "beta"));
    const alpha = result.entries.find((e) => e.name === "alpha")!;
    assert.equal(alpha.isRepo, false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("browseDirectory sorts entries case-insensitively", () => {
  const root = mkdtempSync(join(tmpdir(), "makit-browse-"));
  try {
    mkdirSync(join(root, "Zebra"));
    mkdirSync(join(root, "apple"));
    mkdirSync(join(root, "Mango"));
    const names = browseDirectory(root).entries.map((e) => e.name);
    assert.deepEqual(names, ["apple", "Mango", "Zebra"]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("browseDirectory reports parent null at the filesystem root", () => {
  const result = browseDirectory("/");
  assert.equal(result.path, "/");
  assert.equal(result.parent, null);
});

test("browseDirectory throws on a non-directory path", () => {
  const root = mkdtempSync(join(tmpdir(), "makit-browse-"));
  try {
    assert.throws(() => browseDirectory(join(root, "does-not-exist")));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
