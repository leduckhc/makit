import { test } from "node:test";
import assert from "node:assert/strict";
import { codexSpawnArgs } from "./agent_factory.js";

test("codex spawns plain app-server unless computer use is enabled", () => {
  assert.deepEqual(codexSpawnArgs({}), ["app-server"]);
});

test("computer use appends the cua-driver MCP registration to codex argv", () => {
  const args = codexSpawnArgs({ MAKIT_COMPUTER_USE: "1", MAKIT_CUA_DRIVER_CMD: "/opt/cua-driver" });
  assert.equal(args[0], "app-server", "the subcommand stays first");
  assert.deepEqual(args.slice(1), [
    "-c",
    'mcp_servers.cua_driver.command="/opt/cua-driver"',
    "-c",
    'mcp_servers.cua_driver.args=["mcp"]',
    "-c",
    'mcp_servers.cua_driver.env={CUA_DRIVER_RS_TELEMETRY_ENABLED="0"}',
  ]);
});

test("enabled with no driver present degrades to a plain spawn", () => {
  // The resolver is injected rather than faked through PATH: `resolveBinPath`
  // reads the real `process.env.PATH`, so a PATH in the passed env proves nothing
  // (and silently started passing/failing once cua-driver was installed).
  assert.deepEqual(codexSpawnArgs({ MAKIT_COMPUTER_USE: "1" }, () => undefined), ["app-server"]);
});

test("enabled with a driver from the injected resolver registers it", () => {
  assert.deepEqual(codexSpawnArgs({ MAKIT_COMPUTER_USE: "1" }, () => "/usr/local/bin/cua-driver"), [
    "app-server",
    "-c",
    'mcp_servers.cua_driver.command="/usr/local/bin/cua-driver"',
    "-c",
    'mcp_servers.cua_driver.args=["mcp"]',
    "-c",
    'mcp_servers.cua_driver.env={CUA_DRIVER_RS_TELEMETRY_ENABLED="0"}',
  ]);
});
