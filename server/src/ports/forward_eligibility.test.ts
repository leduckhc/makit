import assert from "node:assert/strict";
import { test } from "node:test";

import { classifyForward, forwardRefusalMessage } from "./forward_eligibility.js";
import type { PortDTO } from "../protocol.js";

function port(overrides: Partial<PortDTO> = {}): PortDTO {
  return {
    key: "200:127.0.0.1:5173",
    port: 5173,
    address: "127.0.0.1",
    reach: "loopback",
    pid: 200,
    command: "node vite",
    worktreePath: "/repo/wt-a",
    openUrl: "http://127.0.0.1:5173",
    ...overrides,
  };
}

const ASK = { worktreePath: "/repo/wt-a", port: 5173, serverPort: 9787 };

test("a loopback, owned, HTTP-answering port is forwardable", () => {
  const decision = classifyForward({ ...ASK, ports: [port()] });
  assert.equal(decision.ok, true);
  assert.equal(decision.port?.port, 5173);
});

test("a port that is not listening is not_found", () => {
  assert.equal(classifyForward({ ...ASK, ports: [] }).refusal, "not_found");
});

test("a port owned by ANOTHER worktree is not_owned", () => {
  const decision = classifyForward({
    ...ASK,
    ports: [port({ worktreePath: "/repo/wt-b" })],
  });
  assert.equal(decision.refusal, "not_owned");
});

test("an UNOWNED listener is not_owned (the kill whitelist's boundary)", () => {
  const decision = classifyForward({ ...ASK, ports: [port({ worktreePath: undefined })] });
  assert.equal(decision.refusal, "not_owned");
});

test("an already-reachable port is refused — forwarding it would be theatre", () => {
  for (const reach of ["exposed", "tailnet"] as const) {
    const decision = classifyForward({ ...ASK, ports: [port({ reach })] });
    assert.equal(decision.refusal, "not_loopback", reach);
  }
});

test("a port that never answered HTTP is refused, not half-forwarded", () => {
  const decision = classifyForward({ ...ASK, ports: [port({ openUrl: undefined })] });
  assert.equal(decision.refusal, "no_http");
});

test("makit's own port is refused (self-proxy is a loop)", () => {
  const decision = classifyForward({
    worktreePath: "/repo/wt-a",
    port: 9787,
    serverPort: 9787,
    ports: [port({ port: 9787, key: "1:127.0.0.1:9787", openUrl: "http://127.0.0.1:9787" })],
  });
  assert.equal(decision.refusal, "is_makit");
});

test("database + shell ports are refused OUTRIGHT, even if owned and HTTP-ish", () => {
  // The threat model in one test: a DB admin UI that assumed it was
  // loopback-only must not become reachable because someone tapped Forward.
  for (const p of [22, 5432, 3306, 6379, 27017, 11211]) {
    const decision = classifyForward({
      worktreePath: "/repo/wt-a",
      port: p,
      serverPort: 9787,
      ports: [
        port({ port: p, key: `9:127.0.0.1:${p}`, openUrl: `http://127.0.0.1:${p}` }),
      ],
    });
    assert.equal(decision.refusal, "protected_service", `port ${p}`);
  }
});

test("every refusal has its own sentence, and none of them is empty", () => {
  for (const refusal of [
    "not_found",
    "not_loopback",
    "not_owned",
    "no_http",
    "is_makit",
    "protected_service",
  ] as const) {
    assert.ok(forwardRefusalMessage(refusal).length > 10, refusal);
  }
});
