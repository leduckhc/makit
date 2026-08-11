/**
 * How every `makit` session verb reaches a running makit (SPEC-46 D1/D2, C4).
 *
 * One place, because the order matters and it is the same for every verb:
 *
 *   1. probe the **control socket** first — a dead daemon is SPEC-02's message
 *      and exit `3`, never a stack trace and never a WSS timeout;
 *   2. resolve the CLI's own credential on that same round trip (an agent's
 *      `MAKIT_CLI_TOKEN`, else `~/.makit/cli.json`, else mint via `cli.grant`);
 *   3. open the WSS socket and `hello`.
 *
 * Anything the server will not accept — a revoked device, a refused `hello`, a
 * port that is not listening — is exit `4`, which is what tells a script "your
 * credential is the problem" apart from "makit isn't running".
 */
import { requireDaemon } from "./require-daemon.js";
import { controlSocketPath } from "../daemon/paths.js";
import { openClient, resolveBearer, AuthError, WireError, type MakitClient } from "./client.js";
import { EXIT_AUTH, EXIT_USAGE } from "./exit-codes.js";

export interface ConnectArgs {
  host: string;
  port: number;
}

/**
 * Print a command failure and exit `1`, with no stack trace.
 *
 * A refusal from the server ("the session tree is at its maximum depth of 3") is
 * an *answer*, not a crash — and the caller is often an agent's `bash`, where an
 * unhandled rejection means a wall of node frames in the transcript instead of the
 * one sentence that explains what happened. Exit `1` because D8 reserves its codes
 * for outcomes a script must distinguish; a refused command is none of them.
 */
export function failCommand(e: unknown): never {
  console.error(`[makit] ${(e as Error).message}`);
  return process.exit(1);
}

/** Print the reason and exit `4` — any credential the server would not take. */
export function failAuth(message: string): never {
  console.error(`[makit] ${message}`);
  return process.exit(EXIT_AUTH);
}

export async function connectCli(args: ConnectArgs): Promise<MakitClient> {
  // A missing or non-numeric value is now rejected where it belongs, by the
  // shared parser, so what is left here is the part parsing cannot know: the
  // range. `--port 0` and `--port 70000` are numbers and still unusable.
  if (!Number.isInteger(args.port) || args.port < 1 || args.port > 65535) {
    console.error(`[makit] --port must be a number in 1..65535, got: ${args.port}`);
    return process.exit(EXIT_USAGE);
  }
  if (args.host.length === 0) {
    console.error("[makit] --host needs a value");
    return process.exit(EXIT_USAGE);
  }

  const control = await requireDaemon(controlSocketPath());
  let bearer: string;
  try {
    bearer = await resolveBearer(control);
  } catch (e) {
    // Closed before exiting: `failAuth` calls `process.exit`, which terminates
    // synchronously, so the `finally` that used to hold this never ran.
    control.close();
    return failAuth((e as Error).message);
  }
  control.close();

  let client: MakitClient;
  try {
    client = await openClient({ host: args.host, port: args.port, bearer });
  } catch (e) {
    // The daemon answered on its control socket but its WSS port did not: from
    // the caller's side that is indistinguishable from a refused credential.
    return failAuth(`could not connect to ${args.host}:${args.port} — ${(e as Error).message}`);
  }
  try {
    await client.hello();
  } catch (e) {
    client.close();
    return failAuth(e instanceof AuthError ? e.message : (e as Error).message);
  }
  return client;
}

/**
 * Connect, run `body`, and guarantee the two things every verb owes its caller:
 * the socket is closed, and a refusal becomes a sentence with a contracted exit
 * code rather than a stack trace (D8).
 *
 * This exists because "connect → try → map the error → finally close" was written
 * out in fourteen verbs and got it right in seven: `send`, `tail`, `wait`,
 * `resume`, `rm`, `respond` and `attach` turned a plain server refusal into an
 * unhandled rejection with an exit code nobody chose. Fixing that one bug seven
 * times, in seven files, is the signature of a missing abstraction — so the
 * contract lives here once and every verb inherits it.
 *
 * `body` may still `process.exit` for its own outcomes (`wait`'s codes, a usage
 * error): that terminates synchronously and skips the `finally`, so anything
 * exiting mid-flight closes the client itself — same as before.
 */
export async function withClient<T>(
  args: ConnectArgs,
  body: (client: MakitClient) => Promise<T>,
): Promise<T | undefined> {
  const client = await connectCli(args);
  try {
    return await body(client);
  } catch (e) {
    // A revoked or refused credential is exit 4; a command the server declined is
    // a sentence and exit 1. Anything else is a real bug and keeps its stack.
    if (e instanceof AuthError) return failAuth(e.message);
    if (e instanceof WireError) return failCommand(e);
    throw e;
  } finally {
    client.close();
  }
}
