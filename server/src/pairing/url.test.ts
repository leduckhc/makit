/**
 * Pair-URL construction tests (SPEC-50 D12).
 *
 * D12 adds two OPTIONAL params (`n`, `id`) to the makit://pair URL so the
 * phone can label each paired server. Back-compat is the hard requirement:
 * when both are absent the URL must be byte-identical to the pre-D12 output,
 * so already-paired phones and older app builds keep parsing.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { buildPairUrl, MAX_PROFILE_NAME_CODE_POINTS } from "./url.js";

const BASE = {
  host: "192.168.1.42",
  port: 8443,
  fingerprint: "ab:cd:ef",
  token: "tok-123",
};

test("without n/id the URL is byte-identical to the pre-D12 output", () => {
  const url = buildPairUrl(BASE);
  assert.equal(
    url,
    "makit://pair?host=192.168.1.42&port=8443&fp=ab%3Acd%3Aef&t=tok-123",
  );
});

test("empty-string name/id are treated as absent (byte-identical)", () => {
  const withEmpties = buildPairUrl({ ...BASE, name: "", id: "" });
  assert.equal(withEmpties, buildPairUrl(BASE));
});

test("name and id are appended as n and id when provided", () => {
  const url = new URL(buildPairUrl({ ...BASE, name: "Work", id: "p_01" }));
  assert.equal(url.searchParams.get("n"), "Work");
  assert.equal(url.searchParams.get("id"), "p_01");
  // fp/t/host/port are untouched.
  assert.equal(url.searchParams.get("host"), "192.168.1.42");
  assert.equal(url.searchParams.get("port"), "8443");
  assert.equal(url.searchParams.get("fp"), "ab:cd:ef");
  assert.equal(url.searchParams.get("t"), "tok-123");
});

test("name is URL-encoded for spaces, & # emoji and non-ASCII", () => {
  const name = "Wörk & Play #1 🎹";
  const raw = buildPairUrl({ ...BASE, name });
  // Round-trips exactly through a parser.
  assert.equal(new URL(raw).searchParams.get("n"), name);
  // The raw string must not contain the literal delimiters that would break
  // parsing — they must be percent-encoded.
  const query = raw.split("?")[1];
  const nSegment = query.split("&").find((s) => s.startsWith("n="))!;
  assert.ok(!nSegment.includes(" "), "space must be encoded");
  assert.ok(!nSegment.includes("#"), "# must be encoded");
  assert.ok(!nSegment.includes("🎹"), "emoji must be encoded");
  // The unencoded '&' would have split into an extra param; assert it didn't.
  assert.equal(new URL(raw).searchParams.get("Play"), null);
});

test("names longer than the cap are truncated at the code-point boundary", () => {
  const long = "x".repeat(MAX_PROFILE_NAME_CODE_POINTS + 50);
  const n = new URL(buildPairUrl({ ...BASE, name: long })).searchParams.get("n")!;
  assert.equal([...n].length, MAX_PROFILE_NAME_CODE_POINTS);
});

test("truncation never splits a multi-code-unit emoji", () => {
  // A string of emoji, each 2 UTF-16 code units, past the cap.
  const long = "🎹".repeat(MAX_PROFILE_NAME_CODE_POINTS + 10);
  const n = new URL(buildPairUrl({ ...BASE, name: long })).searchParams.get("n")!;
  assert.equal([...n].length, MAX_PROFILE_NAME_CODE_POINTS);
  // Every code point is a whole piano emoji — no lone surrogate.
  assert.ok([...n].every((cp) => cp === "🎹"));
});

test("a name exactly at the cap is preserved untouched", () => {
  const exact = "a".repeat(MAX_PROFILE_NAME_CODE_POINTS);
  const n = new URL(buildPairUrl({ ...BASE, name: exact })).searchParams.get("n")!;
  assert.equal(n, exact);
});
