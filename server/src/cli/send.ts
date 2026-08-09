/**
 * `makit send <id> -m MSG [--attach FILE]...` — post a message to a session
 * (SPEC-46 T14). A thin client of `send.message` (D1).
 *
 * `--attach` (SPEC-33) is parsed but **not** wired in T14. Uploading a file
 * means a byte `POST /media` carrying the CLI's bearer over the self-signed
 * loopback cert, plus a mime map — more than the small amount of code the task
 * budgeted, so it is deferred. It is refused with a usage error rather than
 * silently dropped: dropping it would turn "why is this misaligned?" into a
 * text-only turn about an image the agent never receives.
 */
import { AuthError } from "./client.js";
import { connectCli, failAuth } from "./connect.js";
import { EXIT_USAGE } from "./exit-codes.js";

export interface SendArgs {
  host: string;
  port: number;
  sessionId?: string;
  message?: string;
  attach: string[];
}

export function parseSendArgs(argv: string[]): SendArgs {
  const a: SendArgs = { host: "127.0.0.1", port: 7777, attach: [] };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i]!;
    if (t === "--host") a.host = String(argv[++i]);
    else if (t === "--port") a.port = Number(argv[++i]);
    else if (t === "-m" || t === "--message") a.message = String(argv[++i]);
    else if (t === "--attach") a.attach.push(String(argv[++i]));
    else if (!t.startsWith("-") && a.sessionId === undefined) a.sessionId = t;
  }
  return a;
}

function failUsage(message: string): never {
  console.error(`[makit] ${message}`);
  return process.exit(EXIT_USAGE);
}

export async function runSend(argv: string[]): Promise<void> {
  const args = parseSendArgs(argv);
  if (!args.sessionId || args.message === undefined) {
    return failUsage("usage: makit send <id> -m MSG");
  }
  if (args.attach.length > 0) {
    return failUsage("send --attach is not yet supported from the CLI — attach from the app");
  }

  const client = await connectCli(args);
  try {
    await client.cmd("send.message", { sessionId: args.sessionId, text: args.message });
  } catch (e) {
    if (e instanceof AuthError) return failAuth(e.message);
    console.error(`[makit] ${(e as Error).message}`);
    process.exit(1);
  } finally {
    client.close();
  }
}
