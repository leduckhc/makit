import { test } from "node:test";
import assert from "node:assert/strict";

import {
  createForgeDetector,
  forgejoProbeUrl,
  giteaProbeUrl,
  gitlabProbeUrl,
  isGiteaFamilyVersion,
  isGitHubHost,
  NEGATIVE_TTL_MS,
  type ForgeSoftware,
} from "./detect.js";
import type { Http, HttpRequest } from "./forgejo/gateway.js";

/**
 * Scripted HTTP, matched by URL substring. Records every request so the tests can
 * assert on probe COUNT — detection runs once per host, and a detector that
 * re-probes on every lookup would add a round trip to the hot path.
 */
function harness(routes: Array<[string, { status: number; body?: string }]>) {
  const calls: HttpRequest[] = [];
  let nowMs = 1_000;
  const http: Http = async (req) => {
    calls.push(req);
    for (const [needle, res] of routes) {
      if (req.url.includes(needle)) return { status: res.status, body: res.body ?? "", headers: {} };
    }
    return { status: 404, body: "not found", headers: {} };
  };
  const detector = createForgeDetector({ http, now: () => nowMs });
  return { detector, calls, tick: (ms: number) => (nowMs += ms) };
}

const VERSION = (v: string) => JSON.stringify({ version: v });
/** Real payloads, copied from live instances. */
const FORGEJO_V = VERSION("16.0.0+gitea-1.22.0");
const GITEA_V = VERSION("1.27.0+dev-652-g0571722545");

// ---------------------------------------------------------------------------
// Host classification (GitHub needs no probe)
// ---------------------------------------------------------------------------

test("isGitHubHost accepts github.com and subdomains, and no lookalikes", () => {
  assert.equal(isGitHubHost("github.com"), true);
  assert.equal(isGitHubHost("WWW.GitHub.com"), true);
  assert.equal(isGitHubHost("github.com.evil.test"), false);
  assert.equal(isGitHubHost("notgithub.com"), false);
  assert.equal(isGitHubHost("codeberg.org"), false);
});

// ---------------------------------------------------------------------------
// Probe URLs
// ---------------------------------------------------------------------------

test("probe URLs are built off the instance base, trailing slash tolerated", () => {
  assert.equal(forgejoProbeUrl("https://x.test/"), "https://x.test/api/forgejo/v1/version");
  assert.equal(giteaProbeUrl("https://x.test"), "https://x.test/api/v1/version");
  assert.equal(gitlabProbeUrl("https://x.test"), "https://x.test/api/v4/version");
});

test("probe URLs survive a sub-path install", () => {
  assert.equal(forgejoProbeUrl("https://x.test/forge"), "https://x.test/forge/api/forgejo/v1/version");
});

// ---------------------------------------------------------------------------
// Payload classification
// ---------------------------------------------------------------------------

test("isGiteaFamilyVersion accepts a version payload and rejects anything else", () => {
  assert.equal(isGiteaFamilyVersion(FORGEJO_V), true);
  assert.equal(isGiteaFamilyVersion(GITEA_V), true);
  assert.equal(isGiteaFamilyVersion('{"version":""}'), false);
  assert.equal(isGiteaFamilyVersion("{}"), false);
  // GitLab answers /api/v1/version with an HTML redirect to its sign-in page.
  assert.equal(isGiteaFamilyVersion("<html><body>redirected</body></html>"), false);
  assert.equal(isGiteaFamilyVersion(""), false);
});

// ---------------------------------------------------------------------------
// Detection, against the responses real servers actually give
// ---------------------------------------------------------------------------

const detect = async (
  routes: Array<[string, { status: number; body?: string }]>,
): Promise<{ got: ForgeSoftware; probes: number }> => {
  const { detector, calls } = harness(routes);
  const got = await detector.detect("https://git.test");
  return { got, probes: calls.length };
};

test("Forgejo is identified by its own API namespace, in one probe", async () => {
  const { got, probes } = await detect([["/api/forgejo/v1/version", { status: 200, body: FORGEJO_V }]]);
  assert.equal(got, "forgejo");
  assert.equal(probes, 1, "the Forgejo namespace is decisive; do not probe further");
});

test("Gitea is identified by serving /api/v1/version WITHOUT the Forgejo namespace", async () => {
  const { got } = await detect([
    ["/api/forgejo/v1/version", { status: 404 }],
    ["/api/v1/version", { status: 200, body: GITEA_V }],
  ]);
  assert.equal(got, "gitea");
});

test("a Forgejo version string is not mistaken for Gitea when the namespace 404s", async () => {
  // Belt and braces: if a proxy hides /api/forgejo, the `+gitea-` suffix still
  // marks it as Forgejo rather than Gitea.
  const { got } = await detect([
    ["/api/forgejo/v1/version", { status: 404 }],
    ["/api/v1/version", { status: 200, body: FORGEJO_V }],
  ]);
  assert.equal(got, "forgejo");
});

test("GitLab is identified by /api/v4/version answering at all", async () => {
  // 401 unauthenticated is what gitlab.com actually returns, and it is still
  // proof the server is GitLab.
  const { got } = await detect([
    ["/api/forgejo/v1/version", { status: 404 }],
    ["/api/v1/version", { status: 302, body: "<html>redirected</html>" }],
    ["/api/v4/version", { status: 401, body: '{"message":"401 Unauthorized"}' }],
  ]);
  assert.equal(got, "gitlab");
});

test("a server that answers nothing recognisable is `unknown`, not guessed", async () => {
  const { got } = await detect([]);
  assert.equal(got, "unknown");
});

test("an unreachable host is `unknown` rather than throwing", async () => {
  const { got } = await detect([
    ["/api", { status: 0 }],
  ]);
  assert.equal(got, "unknown");
});

// ---------------------------------------------------------------------------
// Caching. Detection is on the hot path's critical section, so it must happen
// once per host -- but a transient failure must NOT pin a host as unsupported.
// ---------------------------------------------------------------------------

test("a positive detection is cached and never re-probed", async () => {
  const { detector, calls } = harness([["/api/forgejo/v1/version", { status: 200, body: FORGEJO_V }]]);
  assert.equal(await detector.detect("https://git.test"), "forgejo");
  const n = calls.length;
  assert.equal(await detector.detect("https://git.test"), "forgejo");
  assert.equal(await detector.detect("https://git.test"), "forgejo");
  assert.equal(calls.length, n);
});

test("a failed detection is retried after a short TTL", async () => {
  // The hazard: an instance down during the first probe would otherwise be pinned
  // as unsupported until the server restarts.
  const routes: Array<[string, { status: number; body?: string }]> = [["/api", { status: 0 }]];
  const { detector, calls, tick } = harness(routes);
  assert.equal(await detector.detect("https://git.test"), "unknown");
  const n = calls.length;
  await detector.detect("https://git.test");
  assert.equal(calls.length, n, "not immediately -- that would hammer a down host");
  tick(NEGATIVE_TTL_MS + 1);
  routes[0] = ["/api/forgejo/v1/version", { status: 200, body: FORGEJO_V }];
  assert.equal(await detector.detect("https://git.test"), "forgejo", "recovery must be possible");
});

test("concurrent first detections for one host share a single probe", async () => {
  const { detector, calls } = harness([["/api/forgejo/v1/version", { status: 200, body: FORGEJO_V }]]);
  const [a, b, c] = await Promise.all([
    detector.detect("https://git.test"),
    detector.detect("https://git.test"),
    detector.detect("https://git.test"),
  ]);
  assert.deepEqual([a, b, c], ["forgejo", "forgejo", "forgejo"]);
  assert.equal(calls.length, 1, "an in-flight probe must be shared");
});

test("detection is keyed per instance, not shared across hosts", async () => {
  const { detector } = harness([
    ["a.test/api/forgejo/v1/version", { status: 200, body: FORGEJO_V }],
    ["b.test/api/forgejo/v1/version", { status: 404 }],
    ["b.test/api/v1/version", { status: 200, body: GITEA_V }],
  ]);
  assert.equal(await detector.detect("https://a.test"), "forgejo");
  assert.equal(await detector.detect("https://b.test"), "gitea");
});

test("a token is sent with the probe, since a private instance 401s without one", async () => {
  const { detector, calls } = harness([["/api/forgejo/v1/version", { status: 200, body: FORGEJO_V }]]);
  await detector.detect("https://git.test", "t0k");
  assert.equal(calls[0].headers.Authorization, "token t0k");
});

test("no Authorization header is sent when there is no token", async () => {
  const { detector, calls } = harness([["/api/forgejo/v1/version", { status: 200, body: FORGEJO_V }]]);
  await detector.detect("https://git.test");
  assert.equal("Authorization" in calls[0].headers, false);
});

test("a gate that 401s every path is NOT reported as GitLab", async () => {
  // Review finding: step 3 treated 401/403 on the GitLab path as proof of GitLab,
  // because "only GitLab serves that path". That holds for the status only if the
  // earlier probes were answered by the APPLICATION. An instance behind SSO or an
  // authenticating reverse proxy answers 401 on every path, including both Forgejo
  // probes — so a perfectly ordinary Forgejo instance behind a gate was classified
  // `gitlab`, routed to the unsupported provider, and the log told the user it
  // "looks like gitlab". When every probe returns the same auth status the responses
  // carry no information about the software, so the honest answer is `unknown` —
  // which is also re-probed later and can be overridden per repo.
  const d = createForgeDetector({
    http: async () => ({ status: 401, body: "", headers: {} }),
  });
  assert.equal(await d.detect("https://gated.example"), "unknown");
});

test("403 on every path is likewise unknown, not GitLab", async () => {
  const d = createForgeDetector({
    http: async () => ({ status: 403, body: "", headers: {} }),
  });
  assert.equal(await d.detect("https://gated.example"), "unknown");
});

test("401 on the GitLab path alone is still GitLab", async () => {
  // The real gitlab.com case: the Forgejo/Gitea probes are ANSWERED (404), so the
  // 401 on /api/v4/version carries information.
  const d = createForgeDetector({
    http: async (req) => {
      if (req.url.includes("/api/v4/version")) return { status: 401, body: "", headers: {} };
      return { status: 404, body: "", headers: {} };
    },
  });
  assert.equal(await d.detect("https://gitlab.example"), "gitlab");
});
