/**
 * Exit codes — the CLI's automation contract (SPEC-cli-as-client D8/C4).
 *
 * Distinct codes exist so a script can tell "the agent finished" from "the agent
 * is blocked on you" from "makit isn't running" without parsing stderr. The
 * turn-outcome codes (`10`/`11`/`20`/`21`) arrive with `makit wait`.
 */

/** Bad usage (unknown flag, missing argument). */
export const EXIT_USAGE = 2;
/** The daemon is not running (SPEC-cli-client-subcommands's convention). */
export const EXIT_NOT_RUNNING = 3;
/** A credential problem: no bearer, revoked, or a refused `hello` (C4). */
export const EXIT_AUTH = 4;
