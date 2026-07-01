/**
 * CommandRouter — an open/closed registry for `cmd` frames.
 *
 * Handlers are registered by `kind` via `register(kind, handler)`; there is no
 * growing switch statement. `dispatch` looks up the handler, invokes it with a
 * typed context, and guarantees:
 *   - an unknown kind → `err {code: bad_request}` (never throws).
 *   - a handler that throws → `err {code: internal}` (never propagates).
 *
 * Handlers receive an `ack`/`err` helper pair pre-bound to the frame id so
 * they never assemble raw envelopes themselves.
 */

import type { Envelope } from "../protocol.js";
import { WireErrorCode } from "../protocol/codec.js";
import type { WsClient } from "./client.js";

export interface CommandContext {
  readonly client: WsClient;
  readonly env: Envelope;
  /** Acknowledge the command, optionally with extra fields (e.g. sessionId). */
  ack(extra?: Record<string, unknown>): void;
  /** Reply with a typed error for this command. */
  err(code: WireErrorCode, message: string): void;
}

export type CommandHandler = (ctx: CommandContext) => void | Promise<void>;

export class CommandRouter {
  private readonly handlers = new Map<string, CommandHandler>();

  /** Register a handler for a command kind. Chainable. */
  register(kind: string, handler: CommandHandler): this {
    this.handlers.set(kind, handler);
    return this;
  }

  /** True if a handler is registered for `kind`. */
  has(kind: string): boolean {
    return this.handlers.has(kind);
  }

  async dispatch(client: WsClient, env: Envelope): Promise<void> {
    const kind = String(env.kind ?? "");
    const ctx = this.contextFor(client, env);

    const handler = this.handlers.get(kind);
    if (!handler) {
      ctx.err(WireErrorCode.BadRequest, `unknown cmd: ${kind}`);
      return;
    }

    try {
      await handler(ctx);
    } catch (e) {
      ctx.err(WireErrorCode.Internal, (e as Error).message);
    }
  }

  private contextFor(client: WsClient, env: Envelope): CommandContext {
    return {
      client,
      env,
      ack: (extra) => client.send({ t: "ack", id: env.id, ...extra }),
      err: (code, message) => client.send({ t: "err", id: env.id, code, message }),
    };
  }
}
