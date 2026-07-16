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
 * first rejection propagates (remaining scheduled tasks still settle, but no
 * new ones start after a rejection surfaces). A non-positive `limit` means
 * "unbounded" (equivalent to `Promise.all`).
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
  const worker = async (): Promise<void> => {
    while (true) {
      const i = next++;
      if (i >= items.length) return;
      results[i] = await fn(items[i], i);
    }
  };
  await Promise.all(Array.from({ length: limit }, () => worker()));
  return results;
}
