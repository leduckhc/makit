/**
 * concurrency.ts — a tiny bounded parallel map.
 *
 * The repo-centric home-screen snapshot fans out to git/gh across every
 * project × worktree. Unbounded `Promise.all` nesting can launch hundreds of
 * child processes at once on a large install (many repos/worktrees), which
 * risks exhausting file-descriptor/process limits and — for the `gh` PR
 * lookups — a network/rate-limit storm. {@link mapLimit} keeps the work
 * parallel but caps how many tasks run concurrently.
 *
 * Semantics mirror `Promise.all`: results are returned in input order and the
 * first rejection propagates. Scheduling is fail-fast — once any task rejects,
 * surviving workers stop claiming queued items (a task already in flight can't
 * be cancelled, so it runs to completion, but no NEW task is started). This
 * matters here: after a git/gh failure we don't want to keep spawning more
 * child processes. A non-positive `limit` means "unbounded" (equivalent to
 * `Promise.all`).
 */
export async function mapLimit<T, R>(
  items: readonly T[],
  limit: number,
  fn: (item: T, index: number) => Promise<R>,
): Promise<R[]> {
  if (limit <= 0 || limit >= items.length) {
    return Promise.all(items.map((item, i) => fn(item, i)));
  }
  const results = new Array<R>(items.length);
  let next = 0;
  let aborted = false;
  const worker = async (): Promise<void> => {
    while (!aborted) {
      const i = next++;
      if (i >= items.length) return;
      try {
        results[i] = await fn(items[i], i);
      } catch (err) {
        // Stop siblings from claiming further work, then surface the error.
        aborted = true;
        throw err;
      }
    }
  };
  await Promise.all(Array.from({ length: limit }, () => worker()));
  return results;
}
