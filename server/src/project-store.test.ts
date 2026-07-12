import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import {
  loadProjectPaths,
  saveProjectPaths,
  browseDirectory,
} from "./project-store.js";

test("saveProjectPaths / loadProjectPaths keeps existing directories", () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-store-"));
  try {
    const file = join(dir, "nested", "projects.json");
    const existing = join(dir, "project");
    mkdirSync(existing);
    const paths = [existing, join(dir, "deleted-project")];
    saveProjectPaths(file, paths);
    assert.deepEqual(loadProjectPaths(file), [existing]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("loadProjectPaths returns [] for a missing file", () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-store-"));
  try {
    assert.deepEqual(loadProjectPaths(join(dir, "nope.json")), []);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("loadProjectPaths returns [] for a malformed file", () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-store-"));
  try {
    const file = join(dir, "bad.json");
    writeFileSync(file, "{ not valid json ");
    assert.deepEqual(loadProjectPaths(file), []);
    writeFileSync(file, JSON.stringify({ projects: "not-an-array" }));
    assert.deepEqual(loadProjectPaths(file), []);
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
