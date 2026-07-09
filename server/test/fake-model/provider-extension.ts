/**
 * pi extension (loaded via `pi -e`) for the real-pi e2e. Registers a custom
 * OpenAI-compatible provider ("makit-fake") that points pi's model client at
 * the local fake model server (test/fake-model/server.ts), whose base URL is
 * passed in via MAKIT_FAKE_MODEL_URL.
 *
 * pi resolves registered providers before `--model` selection, so launching pi
 * with `--model makit-fake/fake-1` selects this stub. The apiKey is a dummy —
 * the fake server ignores auth — but pi requires *some* credential before a
 * model is selectable, so it must be present.
 *
 * This file is transpiled by pi at load time, not by our build. It depends on
 * nothing outside the Node stdlib so it typechecks under the repo tsconfig
 * without pulling in pi's type package.
 */

interface ProviderRegistrar {
  registerProvider(id: string, config: Record<string, unknown>): void;
}

export default function fakeModelProvider(pi: ProviderRegistrar): void {
  const baseUrl = process.env.MAKIT_FAKE_MODEL_URL;
  if (!baseUrl) {
    throw new Error("MAKIT_FAKE_MODEL_URL is not set — fake model server URL required");
  }

  pi.registerProvider("makit-fake", {
    name: "Makit Fake",
    baseUrl,
    api: "openai-completions",
    apiKey: "makit-e2e-fake-key",
    models: [
      {
        id: "fake-1",
        name: "Fake 1",
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 128_000,
        maxTokens: 4096,
      },
    ],
  });
}
