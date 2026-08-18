import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:makit/store/models.dart';
import 'package:makit/store/docs.dart';
import 'package:makit/ui/home/worktree_row.dart';

/// SPEC-doc-preview P1 — the mobile entry point must not be a dead end.
///
/// The Docs screen is reached on the phone from the worktree row's docs glyph,
/// and that glyph renders nothing when the worktree owns no docs. So if nothing
/// holds `docs.watch` while the home screen is up, the server never sends a
/// `docs.snapshot`, the doc list stays empty, the glyph never appears — and the
/// Docs screen becomes unreachable on mobile entirely.
///
/// This is invisible to every other widget test in the suite, because they
/// inject `docsProvider` directly instead of letting it arrive over the wire.
/// The row therefore has to hold the watch itself, exactly as it already holds
/// `ports.watch` for the ports plug (SPEC-open-ports §Delivery).
void main() {
  testWidgets('mounting worktree rows collapses to one docs.watch', (
    tester,
  ) async {
    // Record only the on/off edges: a Map literal is never `==` to another Map
    // in Dart, so matching on maps would silently never match.
    final sent = <bool>[];

    const repo = RepoInfo(
      id: 'p1',
      name: 'demo',
      path: '/tmp/demo',
      pinned: true,
      lastActivityAt: 0,
      isGitRepo: true,
      defaultBranch: 'main',
      currentBranch: 'main',
      worktrees: [],
    );
    const worktreeA = Worktree(
      id: '/tmp/demo',
      path: '/tmp/demo',
      branch: 'main',
      isPrimary: true,
      insertions: 0,
      deletions: 0,
      filesChanged: 0,
      sessionIds: [],
    );
    const worktreeB = Worktree(
      id: '/tmp/demo-b',
      path: '/tmp/demo-b',
      branch: 'feature',
      isPrimary: false,
      insertions: 0,
      deletions: 0,
      filesChanged: 0,
      sessionIds: [],
    );

    // Riverpod forbids changing the NUMBER of overrides between pumps, so the
    // scope is built once and only its child is swapped below.
    Widget host(Widget child) => ProviderScope(
      overrides: [
        // Capture what the rows ask the server for, without a socket.
        docsWatchProvider.overrideWithValue(DocsWatch(sent.add)),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    );

    // Two rows mounted at once must collapse to a single `docs.watch {on:true}`
    // via the ref count — a regression that sent one message per row would
    // wrongly produce `[true, true]`.
    await tester.pumpWidget(
      host(
        const Column(
          children: [
            WorktreeRow(repo: repo, worktree: worktreeA, sessions: []),
            WorktreeRow(repo: repo, worktree: worktreeB, sessions: []),
          ],
        ),
      ),
    );
    expect(
      sent,
      equals([true]),
      reason:
          'the rows must share one docs.watch, or the docs glyph can never '
          'appear and the Docs screen is unreachable on mobile',
    );

    // Unmounting one row keeps a live watcher, so nothing new is sent.
    await tester.pumpWidget(
      host(
        const Column(
          children: [
            WorktreeRow(repo: repo, worktree: worktreeA, sessions: []),
          ],
        ),
      ),
    );
    expect(
      sent,
      equals([true]),
      reason: 'a surviving row must hold the watch open',
    );

    // The last release must let go, so a backgrounded app stops the index walk.
    await tester.pumpWidget(host(const SizedBox()));
    expect(sent, equals([true, false]), reason: 'the watch must be released');
  });
}
