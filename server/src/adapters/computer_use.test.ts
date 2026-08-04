import { test } from "node:test";
import assert from "node:assert/strict";
import { resolveComputerUse, codexComputerUseArgs, tomlString } from "./computer_use.js";

test("computer use is off unless explicitly enabled", () => {
  const found = () => "/usr/local/bin/cua-driver";
  assert.deepEqual(resolveComputerUse({}, found), { enabled: false, reason: "not-enabled" });
  assert.deepEqual(resolveComputerUse({ MAKIT_COMPUTER_USE: "0" }, found), { enabled: false, reason: "not-enabled" });
  assert.deepEqual(resolveComputerUse({ MAKIT_COMPUTER_USE: "1" }, found), {
    enabled: true,
    driverPath: "/usr/local/bin/cua-driver",
  });
});

test("enabled but with no driver on PATH reports a distinct reason", () => {
  assert.deepEqual(resolveComputerUse({ MAKIT_COMPUTER_USE: "1" }, () => undefined), {
    enabled: false,
    reason: "driver-missing",
  });
});

test("an explicit driver path wins over PATH lookup", () => {
  const res = resolveComputerUse(
    { MAKIT_COMPUTER_USE: "1", MAKIT_CUA_DRIVER_CMD: "/tmp/build/cua-driver" },
    () => "/usr/local/bin/cua-driver",
  );
  assert.deepEqual(res, { enabled: true, driverPath: "/tmp/build/cua-driver" });
});

test("codex args register cua-driver as a stdio MCP server with telemetry off", () => {
  assert.deepEqual(codexComputerUseArgs("/usr/local/bin/cua-driver"), [
    "-c",
    'mcp_servers.cua_driver.command="/usr/local/bin/cua-driver"',
    "-c",
    'mcp_servers.cua_driver.args=["mcp"]',
    "-c",
    'mcp_servers.cua_driver.env={CUA_DRIVER_RS_TELEMETRY_ENABLED="0"}',
  ]);
});

test("a driver path with TOML metacharacters is escaped, not injected", () => {
  assert.equal(tomlString('/tmp/we"ird\\path'), '"/tmp/we\\"ird\\\\path"');
  const args = codexComputerUseArgs('/tmp/we"ird/cua-driver');
  assert.equal(args[1], 'mcp_servers.cua_driver.command="/tmp/we\\"ird/cua-driver"');
});
