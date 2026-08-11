/**
 * The CLI's stdout seam.
 *
 * Streaming verbs (`tail`, `run`) print partial lines — `renderEvent` grows an
 * agent bubble on one line — so they cannot use `console.log`, which would add a
 * newline per chunk. Writing straight to `process.stdout` is the obvious
 * alternative and it broke the test suite: a test that swaps
 * `process.stdout.write` also swallows `node --test`'s own result stream, which
 * silently drops whole tests from the report. So the write goes through this
 * indirection, and tests replace `stdout.write` here instead of the global.
 */
export const stdout = {
  write(s: string): void {
    process.stdout.write(s);
  },
};
