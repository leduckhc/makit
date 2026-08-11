/**
 * `makit send <id> -m MSG [--attach FILE]...` — post a message to a session
 * (SPEC-46 T14). A thin client of `send.message` (D1).
 *
 * `--attach` (SPEC-33) uploads each file to `POST /media` and references the
 * returned `mediaId` on the turn. Every failure on that path — an unstorable
 * type, an unreadable file, a refused upload — **fails the whole send**. Sending
 * the text alone would turn "why is this misaligned?" into a question about an
 * image the agent never received, and the user would read a confident answer
 * about nothing.
 */
import { readFileSync } from "node:fs";
import { basename } from "node:path";
import { withClient } from "./connect.js";
import { EXIT_USAGE } from "./exit-codes.js";
import { ATTACHABLE, mimeForPath, uploadMedia } from "./media_upload.js";

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
  // Resolved before connecting: an attachment makit could never store must not
  // leave a turn (or an upload) behind it.
  const files = args.attach.map((path) => {
    const mime = mimeForPath(path);
    if (!mime) return failUsage(`cannot attach ${basename(path)} — makit stores ${ATTACHABLE}`);
    try {
      return { path, mime, bytes: readFileSync(path) };
    } catch (e) {
      return failUsage(`cannot read ${path}: ${(e as Error).message}`);
    }
  });

  await withClient(args, async (client) => {
    const attachments: { mediaId: string; name: string }[] = [];
    for (const f of files) {
      const mediaId = await uploadMedia(
        { host: args.host, port: args.port, bearer: client.bearer },
        f.path,
        f.bytes,
        f.mime,
      );
      attachments.push({ mediaId, name: basename(f.path) });
    }
    await client.cmd("send.message", {
      sessionId: args.sessionId,
      text: args.message,
      attachments: attachments.length > 0 ? attachments : undefined,
    });
  });
}
