#!/usr/bin/env tsx

/**
 * E2E comparison: codex-acp vs codex app-server
 * Both against gpt-5.4-mini, same prompt that triggers user input.
 *
 * Measures:
 *   - Time to first token
 *   - Time to first user-input request
 *   - Input question richness (options, multiselect, etc)
 *   - Overall latency
 */

import { spawn } from "node:child_process";
import { createReadStream, existsSync, unlinkSync } from "node:fs";
import * as readline from "node:readline";
import type { ChildProcessWithoutNullStreams } from "node:child_process";

// ─────────────────────────────────────────────────────────────────────────────

interface ComparisonResult {
  adapter: "codex-acp" | "codex app-server";
  prompt: string;
  startTime: number;
  firstTokenTime?: number;
  firstInputTime?: number;
  finishTime?: number;
  events: string[];
  userInputCount: number;
  approvalCount: number;
  errors: string[];
}

async function runCodexAcp(prompt: string): Promise<ComparisonResult> {
  const result: ComparisonResult = {
    adapter: "codex-acp",
    prompt,
    startTime: Date.now(),
    events: [],
    userInputCount: 0,
    approvalCount: 0,
    errors: [],
  };

  return new Promise((resolve, reject) => {
    const proc = spawn(
      "./node_modules/.bin/codex-acp",
      ["-c", 'model="gpt-5.4-mini"'],
      { stdio: ["pipe", "pipe", "pipe"] },
    );

    let buffer = "";
    let responseTime: number | undefined;

    const onClose = () => {
      result.finishTime = Date.now();
      result.events.push(
        `total: ${result.finishTime - result.startTime}ms, user-inputs: ${result.userInputCount}, approvals: ${result.approvalCount}`,
      );
      resolve(result);
    };

    proc.stdout?.on("data", (chunk) => {
      buffer += chunk.toString();
      const lines = buffer.split("\n");
      buffer = lines.pop() || "";

      for (const line of lines) {
        if (!line.trim()) continue;

        try {
          const msg = JSON.parse(line);

          // Track first response.
          if (!responseTime && (msg.result || msg.params)) {
            responseTime = Date.now();
            result.firstTokenTime = responseTime - result.startTime;
          }

          // Count user input requests.
          if (msg.method === "createElicitation") {
            result.userInputCount++;
            if (!result.firstInputTime) {
              result.firstInputTime = Date.now() - result.startTime;
            }
            result.events.push(`[elicit] ${msg.params?.mode ?? "unknown"}`);
          }

          // Count permission requests.
          if (msg.method === "requestPermission") {
            result.approvalCount++;
            result.events.push(`[approval] ${msg.params?.toolCall?.kind ?? "unknown"}`);
          }

          // Track completion.
          if (msg.result?.protocolVersion) {
            result.events.push("[init]");
          }
        } catch (e) {
          // Ignore parse errors on partial lines.
        }
      }
    });

    // Send initialize.
    const initMsg = { id: 1, method: "initialize", params: {} };
    proc.stdin?.write(JSON.stringify(initMsg) + "\n");

    // Send newSession after a brief delay.
    setTimeout(() => {
      const newSessionMsg = { id: 2, method: "newSession", params: {} };
      proc.stdin?.write(JSON.stringify(newSessionMsg) + "\n");

      // Send prompt after another delay.
      setTimeout(() => {
        const promptMsg = {
          id: 3,
          method: "prompt",
          params: {
            sessionId: "session-1",
            messages: [
              {
                role: "user",
                content: [{ type: "text", text: prompt }],
              },
            ],
          },
        };
        proc.stdin?.write(JSON.stringify(promptMsg) + "\n");

        // Let it run for 5 seconds, then kill.
        setTimeout(() => {
          proc.kill();
          onClose();
        }, 5000);
      }, 100);
    }, 100);

    proc.stderr?.on("data", (chunk) => {
      result.errors.push(chunk.toString());
    });

    proc.on("close", onClose);
    proc.on("error", (e) => reject(e));
  });
}

async function runCodexAppServer(prompt: string): Promise<ComparisonResult> {
  const result: ComparisonResult = {
    adapter: "codex app-server",
    prompt,
    startTime: Date.now(),
    events: [],
    userInputCount: 0,
    approvalCount: 0,
    errors: [],
  };

  return new Promise((resolve, reject) => {
    const proc = spawn("codex", ["app-server"], { stdio: ["pipe", "pipe", "pipe"] });

    let buffer = "";
    let responseTime: number | undefined;

    const onClose = () => {
      result.finishTime = Date.now();
      result.events.push(
        `total: ${result.finishTime - result.startTime}ms, user-inputs: ${result.userInputCount}, approvals: ${result.approvalCount}`,
      );
      resolve(result);
    };

    proc.stdout?.on("data", (chunk) => {
      buffer += chunk.toString();
      const lines = buffer.split("\n");
      buffer = lines.pop() || "";

      for (const line of lines) {
        if (!line.trim()) continue;

        try {
          const msg = JSON.parse(line);

          // Track first response.
          if (!responseTime && (msg.result || msg.params)) {
            responseTime = Date.now();
            result.firstTokenTime = responseTime - result.startTime;
          }

          // Count user input requests.
          if (msg.method === "item/tool/requestUserInput") {
            result.userInputCount++;
            if (!result.firstInputTime) {
              result.firstInputTime = Date.now() - result.startTime;
            }
            const questions = msg.params?.questions ?? [];
            result.events.push(
              `[input] ${questions.length} question(s), multiselect=${questions[0]?.multiSelect ?? false}`,
            );
          }

          // Count approval requests.
          if (msg.method === "item/requestApproval") {
            result.approvalCount++;
            result.events.push(`[approval] ${msg.params?.toolName ?? "unknown"}`);
          }

          // Track completion.
          if (msg.result?.userAgent) {
            result.events.push("[init]");
          }
        } catch (e) {
          // Ignore parse errors.
        }
      }
    });

    // Send initialize.
    const initMsg = {
      id: 1,
      method: "client/initialize",
      params: { clientInfo: { name: "makit", version: "0.1.0" } },
    };
    proc.stdin?.write(JSON.stringify(initMsg) + "\n");

    // Send thread/start after a brief delay.
    setTimeout(() => {
      const threadMsg = {
        id: 2,
        method: "v2/thread/start",
        params: { workingDirectory: process.cwd(), model: "gpt-4o" },
      };
      proc.stdin?.write(JSON.stringify(threadMsg) + "\n");

      // Send turn/start with the prompt after another delay.
      setTimeout(() => {
        const turnMsg = {
          id: 3,
          method: "v2/turn/start",
          params: {
            threadId: "thread-1",
            userMessage: {
              content: [{ type: "text", text: prompt }],
            },
          },
        };
        proc.stdin?.write(JSON.stringify(turnMsg) + "\n");

        // Let it run for 5 seconds, then kill.
        setTimeout(() => {
          proc.kill();
          onClose();
        }, 5000);
      }, 100);
    }, 100);

    proc.stderr?.on("data", (chunk) => {
      result.errors.push(chunk.toString());
    });

    proc.on("close", onClose);
    proc.on("error", (e) => reject(e));
  });
}

// ─────────────────────────────────────────────────────────────────────────────

async function main() {
  const prompt =
    "Ask me a multi-choice question about how to deploy a web app. Include at least 3 options.";

  console.log("=".repeat(80));
  console.log("COMPARISON: codex-acp vs codex app-server");
  console.log("=".repeat(80));
  console.log(`Prompt: "${prompt}"\n`);

  console.log("Running codex-acp...");
  const acpResult = await runCodexAcp(prompt);

  console.log("\nRunning codex app-server...");
  const appServerResult = await runCodexAppServer(prompt);

  // ─────────────────────────────────────────────────────────────────────────

  console.log("\n" + "=".repeat(80));
  console.log("RESULTS");
  console.log("=".repeat(80));

  const printResult = (r: ComparisonResult) => {
    console.log(`\n[${r.adapter.toUpperCase()}]`);
    console.log(`  First token:     ${r.firstTokenTime ?? "N/A"}ms`);
    console.log(`  First input req: ${r.firstInputTime ?? "N/A"}ms`);
    console.log(`  Total time:      ${r.finishTime ? r.finishTime - r.startTime : "N/A"}ms`);
    console.log(`  User inputs:     ${r.userInputCount}`);
    console.log(`  Approvals:       ${r.approvalCount}`);
    console.log(`  Events:`);
    r.events.forEach((e) => console.log(`    - ${e}`));
    if (r.errors.length) {
      console.log(`  Errors:`);
      r.errors.slice(0, 3).forEach((e) => console.log(`    - ${e.substring(0, 120)}`));
    }
  };

  printResult(acpResult);
  printResult(appServerResult);

  console.log("\n" + "=".repeat(80));
  console.log("COMPARISON SUMMARY");
  console.log("=".repeat(80));

  const timeDiff =
    acpResult.firstTokenTime && appServerResult.firstTokenTime
      ? Math.abs(acpResult.firstTokenTime - appServerResult.firstTokenTime)
      : null;

  console.log(`
codex-acp:
  - First token latency: ${acpResult.firstTokenTime ?? "N/A"}ms
  - User input handling: ${acpResult.userInputCount > 0 ? "✓ YES" : "✗ NO"} (${acpResult.userInputCount} request(s))
  - User question format: ${acpResult.userInputCount > 0 ? "elicitation mode" : "N/A"}

codex app-server:
  - First token latency: ${appServerResult.firstTokenTime ?? "N/A"}ms
  - User input handling: ${appServerResult.userInputCount > 0 ? "✓ YES" : "✗ NO"} (${appServerResult.userInputCount} request(s))
  - User question format: ${appServerResult.userInputCount > 0 ? "item/tool/requestUserInput (multiselect, textarea, options)" : "N/A"}

Latency difference: ${timeDiff !== null ? `${timeDiff}ms` : "N/A"}
Better: ${
    timeDiff !== null
      ? acpResult.firstTokenTime! < appServerResult.firstTokenTime!
        ? "codex-acp"
        : "codex app-server"
      : "N/A"
  }
`);
}

main().catch(console.error);
