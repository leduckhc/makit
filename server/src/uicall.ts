/**
 * Canonical UICall schema — vendor-neutral language between agents and makit app.
 *
 * Agent connectors (server/connectors/*.ts) translate native tool params into
 * one of these variants, POST to the loopback HTTP bridge, and receive the
 * user's choice. The app has a single dispatcher (SrvRequestHandler) that
 * renders the appropriate UI for each `kind`.
 *
 * To add a new UI interaction:
 *   1. Add a variant to the UICall union here (e.g., ConfirmAction, EditFile).
 *   2. Add a renderer in app/lib/ui/widgets/srv_request_handler.dart.
 *   3. Both can evolve independently as long as the TSM stays stable.
 *
 * Why union not enum: the payload is different for each kind. pi's
 * askUserQuestion looks nothing like claude's tool_use_block preview, etc.
 */

export type UICall =
  | AskUserQuestionCall
  | ConfirmActionCall
  | InputCall;

/**
 * A callback that presents a UICall on the user's phone and resolves with
 * their answer. Used by both the HTTP bridge (connector tools) and the
 * PiAdapter UI interceptor (transparent ctx.ui.* transport).
 */
export type AskUser = (call: UICall & { sessionId?: string }) => Promise<UIResponse>;

/**
 * Prompt the user to pick from 1–4 survey-style questions, each with 2–4 options.
 * Mirrors the Anthropic-standard `tool_use_block` for `askUserQuestion`.
 *
 * Response: `{ kind: "askUserQuestion", indices: number[], answers: string[], answer?: string }`
 */
export interface AskUserQuestionCall {
  kind: "askUserQuestion";
  questions: {
    header?: string;
    question: string;
    options: {
      label: string;
      description?: string;
    }[];
    multi?: boolean;
    recommended?: number;
  }[];
}

/**
 * Prompt the user to approve or deny a risky action (e.g., "Run `rm -rf /`?").
 * Used by connectors that implement mid-turn approvals.
 *
 * Response: `{ kind: "confirmAction", approved: boolean }`
 */
export interface ConfirmActionCall {
  kind: "confirmAction";
  title: string;
  message: string;
  /** Optional details to show before the action runs (e.g. command preview). */
  preview?: string;
  /**
   * The action that would run if approved. Shown in the confirmation UI.
   * E.g. "bash", "file_edit", "network_request".
   */
  action: string;
}

/**
 * Response envelope from the app — what the user chose.
 * Always includes `kind` to let connectors dispatch back to the agent.
 */
export type UIResponse =
  | AskUserQuestionResponse
  | ConfirmActionResponse
  | InputResponse;

export interface AskUserQuestionResponse {
  kind: "askUserQuestion";
  /** Array of selected option indices (one per question). */
  indices: number[];
  /** Array of selected labels (one per question). */
  answers: string[];
  /** Convenience: if single-question form, this is the one answer. */
  answer?: string;
}

export interface ConfirmActionResponse {
  kind: "confirmAction";
  approved: boolean;
}

/**
 * Prompt the user for a single free-text value. Maps pi's `ctx.ui.input` and
 * `ctx.ui.editor` (multiline). Used by the PiAdapter UI interceptor.
 *
 * Response: `{ kind: "input", value?: string, cancelled?: boolean }`
 */
export interface InputCall {
  kind: "input";
  title: string;
  placeholder?: string;
  /** Prefilled text (from ctx.ui.editor). */
  prefill?: string;
  /** Render a multiline editor (ctx.ui.editor) vs a single-line field. */
  multiline?: boolean;
}

export interface InputResponse {
  kind: "input";
  value?: string;
  cancelled?: boolean;
}
