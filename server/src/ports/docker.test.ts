import assert from "node:assert/strict";
import { test } from "node:test";

import {
  DOCKER_TTL_MS,
  createDockerReader,
  isDockerBackend,
  parseDockerPs,
} from "./docker.js";
import type { Exec } from "./scan.js";

const PS_LINE = [
  "chat-ui-db-1",
  "0.0.0.0:5432->5432/tcp, :::5432->5432/tcp",
  "/repo/chat-ui/compose.yml",
].join("\t");

/** An `exec` that records every call and answers with the given result. */
function recordingExec(
  result: { code: number; stdout: string; stderr: string },
): { exec: Exec; calls: () => number } {
  let calls = 0;
  return {
    exec: async () => {
      calls++;
      return result;
    },
    calls: () => calls,
  };
}

test("parseDockerPs maps a published host port to its container", () => {
  const map = parseDockerPs(PS_LINE);
  assert.deepEqual([...map.keys()], [5432]);
  assert.equal(map.get(5432)?.container, "chat-ui-db-1");
  assert.equal(map.get(5432)?.compose, "/repo/chat-ui/compose.yml");
});

test("parseDockerPs omits compose when the label is absent", () => {
  const map = parseDockerPs(["redis", "127.0.0.1:6380->6379/tcp", ""].join("\t"));
  assert.equal(map.get(6380)?.container, "redis");
  assert.equal(
    map.get(6380)?.compose,
    undefined,
    "a plain `docker run` has no compose file — absent, never guessed",
  );
});

test("parseDockerPs keeps the FIRST file of a multi-file compose label", () => {
  const map = parseDockerPs(
    ["api", "0.0.0.0:8080->80/tcp", "/a/compose.yml,/a/compose.override.yml"].join("\t"),
  );
  assert.equal(map.get(8080)?.compose, "/a/compose.yml");
});

test("parseDockerPs ignores containers with no published host port", () => {
  // An unpublished port (`5432/tcp`) is reachable only inside the docker
  // network, so nothing on the host is listening for it to annotate.
  const map = parseDockerPs(["internal-db", "5432/tcp", ""].join("\t"));
  assert.equal(map.size, 0);
});

test("parseDockerPs skips udp publishes and survives malformed rows", () => {
  const map = parseDockerPs(
    [
      ["dns", "0.0.0.0:5353->53/udp", ""].join("\t"),
      "garbage-with-no-tabs",
      "\t\t", // empty name
      PS_LINE,
    ].join("\n"),
  );
  assert.deepEqual(
    [...map.keys()],
    [5432],
    "UDP is out of scope (SPEC-41) and one odd row must not blind the read",
  );
});

test("parseDockerPs maps a host port that differs from the container port", () => {
  const map = parseDockerPs(["cache", "0.0.0.0:32768->6379/tcp", ""].join("\t"));
  assert.deepEqual([...map.keys()], [32768], "the HOST port is what lsof sees");
});

test("a non-zero `docker ps` yields ok:false and NO annotations", async () => {
  // The `run()` 127 trap: a missing binary resolves (never rejects) with
  // `{code:127, stdout:""}`, which must read as "unknown", not "no containers".
  const { exec } = recordingExec({ code: 127, stdout: "", stderr: "spawn docker ENOENT" });
  const read = createDockerReader(exec, () => 0);
  const result = await read();
  assert.equal(result.ok, false);
  assert.equal(result.byHostPort.size, 0);
});

test("a throwing exec yields ok:false, never a rejection", async () => {
  const read = createDockerReader(async () => {
    throw new Error("boom");
  }, () => 0);
  const result = await read();
  assert.equal(result.ok, false);
  assert.equal(result.byHostPort.size, 0);
});

test("the TTL cache reuses within DOCKER_TTL_MS and re-reads after", async () => {
  const { exec, calls } = recordingExec({ code: 0, stdout: PS_LINE, stderr: "" });
  let now = 1_000;
  const read = createDockerReader(exec, () => now);

  await read();
  await read();
  assert.equal(calls(), 1, "a second read inside the TTL must not spawn `docker ps` again");

  now += DOCKER_TTL_MS - 1;
  await read();
  assert.equal(calls(), 1, "still inside the window");

  now += 1;
  const fresh = await read();
  assert.equal(calls(), 2, "the window elapsed — read again");
  assert.equal(fresh.byHostPort.get(5432)?.container, "chat-ui-db-1");
});

test("a MISSING binary is never probed again; a down daemon is retried", async () => {
  // ENOENT means docker is not installed: paying for that exec every 10 s
  // forever is the cost D13 promises to skip. A daemon that is merely not
  // running (non-zero exit, real stderr) may come up, so it keeps its TTL.
  let stderr = "spawn docker ENOENT";
  let code = 127;
  let calls = 0;
  let now = 0;
  const read = createDockerReader(async () => {
    calls++;
    return { code, stdout: "", stderr };
  }, () => now);

  await read();
  now += DOCKER_TTL_MS * 10;
  await read();
  assert.equal(calls, 1, "no docker binary — never spawn it again");

  code = 1;
  stderr = "Cannot connect to the Docker daemon at unix:///var/run/docker.sock.";
  const retried = createDockerReader(async () => {
    calls++;
    return { code, stdout: "", stderr };
  }, () => now);
  await retried();
  now += DOCKER_TTL_MS;
  await retried();
  assert.equal(calls, 3, "a stopped daemon is retried on the next TTL tick");
});

test("isDockerBackend recognises the host-side proxy, and nothing else", () => {
  // Only the process docker itself uses to hold the published host port may
  // take the annotation: a NATIVE postgres on 5432 must never be relabelled as
  // a container just because a container publishes the same port number.
  assert.equal(isDockerBackend("/Applications/Docker.app/.../com.docker.backend"), true);
  assert.equal(isDockerBackend("/usr/bin/docker-proxy -container-ip 172.17.0.2"), true);
  assert.equal(isDockerBackend("dockerd --host=unix:///var/run/docker.sock"), true);
  assert.equal(isDockerBackend("/opt/homebrew/opt/postgresql@16/bin/postgres -D /data"), false);
  assert.equal(isDockerBackend("node vite --port 5173"), false);
  assert.equal(
    isDockerBackend("node build-docker-image.js"),
    false,
    "a substring match on 'docker' would annotate any command that mentions it",
  );
});
