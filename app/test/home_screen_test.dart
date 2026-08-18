import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:makit/app/theme.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/home/home_screen.dart';
import 'package:makit/ui/widgets/glass.dart';

Widget _host({required List<RepoInfo> repos, required List<Session> sessions}) {
  return ProviderScope(
    overrides: [
      reposProvider.overrideWithValue(ReposState(repos)),
      sessionsProvider.overrideWithValue(SessionsState(sessions)),
    ],
    child: const MaterialApp(home: HomeScreen()),
  );
}

/// A repo with one worktree (the primary checkout on `main`).
RepoInfo _repo({
  String id = 'p1',
  String name = 'demo',
  List<Worktree> worktrees = const [],
}) => RepoInfo(
  id: id,
  name: name,
  path: '/tmp/$name',
  pinned: true,
  lastActivityAt: 0,
  isGitRepo: true,
  defaultBranch: 'main',
  currentBranch: 'main',
  worktrees: worktrees.isEmpty
      ? [
          const Worktree(
            id: '/tmp/demo',
            path: '/tmp/demo',
            branch: 'main',
            isPrimary: true,
            insertions: 0,
            deletions: 0,
            filesChanged: 0,
            sessionIds: [],
          ),
        ]
      : worktrees,
);

Session _session({
  String id = 's1',
  String agent = 'pi',
  String title = 'work',
  SessionStatus status = SessionStatus.idle,
  bool pending = false,
}) => Session(
  id: id,
  projectId: 'p1',
  agent: agent,
  title: title,
  status: status,
  policy: ApprovalPolicy.askOnRisky,
  pending: pending,
);

void main() {
  testWidgets('empty state is a glass card with its CTA', (tester) async {
    await tester.pumpWidget(_host(repos: const [], sessions: const []));
    await tester.pump();

    expect(find.byType(GlassSurface), findsWidgets);
    expect(find.text('Add repo'), findsOneWidget);
  });

  testWidgets('the current branch worktree is marked with a star', (
    tester,
  ) async {
    // Primary worktree is on `main` (== currentBranch) and has a live session
    // so it renders; it should carry the current-branch star.
    await tester.pumpWidget(
      _host(
        repos: [
          _repo(
            worktrees: [
              const Worktree(
                id: '/tmp/demo',
                path: '/tmp/demo',
                branch: 'main',
                isPrimary: true,
                insertions: 0,
                deletions: 0,
                filesChanged: 0,
                sessionIds: ['s1'],
              ),
            ],
          ),
        ],
        sessions: [_session()],
      ),
    );
    await tester.pump();

    expect(find.byIcon(PhosphorIconsFill.star), findsOneWidget);
  });

  testWidgets('a worktree with no live session still renders', (tester) async {
    // Matching the desktop sidebar (SPEC-repo-centric-home): every worktree is listed, whether
    // or not a session is running in it — a branch with work on it is the thing
    // you most want to start a session *on*, so hiding it hid the entry point.
    final repo = _repo(
      worktrees: [
        const Worktree(
          id: '/wt/feature',
          path: '/wt/feature',
          branch: 'add-login',
          isPrimary: false,
          insertions: 42,
          deletions: 7,
          filesChanged: 3,
          sessionIds: [],
        ),
      ],
    );
    await tester.pumpWidget(_host(repos: [repo], sessions: const []));
    await tester.pump();

    expect(find.text('add-login'), findsOneWidget);
    // Its diff stats come with it, so the row is worth the space it takes.
    expect(find.text('+42'), findsWidgets);
  });

  testWidgets('a worktree with changes renders a +/- diff chip', (
    tester,
  ) async {
    final repo = _repo(
      worktrees: [
        const Worktree(
          id: '/tmp/demo',
          path: '/tmp/demo',
          branch: 'main',
          isPrimary: true,
          insertions: 0,
          deletions: 0,
          filesChanged: 0,
          sessionIds: [],
        ),
        const Worktree(
          id: '/wt/feature',
          path: '/wt/feature',
          branch: 'add-login',
          isPrimary: false,
          insertions: 42,
          deletions: 7,
          filesChanged: 3,
          sessionIds: ['s1'],
        ),
      ],
    );
    await tester.pumpWidget(_host(repos: [repo], sessions: [_session()]));
    await tester.pump();

    expect(find.text('add-login'), findsOneWidget);
    expect(find.text('+42'), findsWidgets);
    expect(find.text('−7'), findsWidgets);
  });

  testWidgets('an open PR is named, with its state in words', (tester) async {
    final repo = _repo(
      worktrees: [
        const Worktree(
          id: '/wt/feature',
          path: '/wt/feature',
          branch: 'add-login',
          isPrimary: false,
          insertions: 10,
          deletions: 0,
          filesChanged: 1,
          sessionIds: ['s1'],
          pr: PullRequest(
            number: 42,
            url: 'https://x/pull/42',
            state: 'OPEN',
            title: 'Add login',
            isDraft: false,
          ),
        ),
      ],
    );
    await tester.pumpWidget(_host(repos: [repo], sessions: [_session()]));
    await tester.pump();

    // The row used to carry a bare `PR #42` pill whose colour was the only
    // signal. It now says what the PR needs — here, nothing (checkRollup is
    // 'none', so there is no verdict to report and no work outstanding).
    expect(find.text('#42 · green and up to date'), findsOneWidget);
    // The repo card's header counts it as one *open* PR — a compact pill, since
    // the per-worktree chip already spells the number out.
    expect(
      find.descendant(
        of: find.byKey(const Key('openPrCount')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a branch named like a PR number is not treated as one', (
    tester,
  ) async {
    // `#42` is a legal branch name. Deciding "this has a PR" by looking at the
    // display string classified such a branch as one, so the chip repeated the
    // branch name the row already shows and drew a filled (has-a-PR) dot.
    final repo = _repo(
      worktrees: [
        const Worktree(
          id: '/wt/hash',
          path: '/wt/hash',
          branch: '#42',
          isPrimary: false,
          insertions: 0,
          deletions: 0,
          filesChanged: 0,
          uncommittedFiles: 3,
          sessionIds: ['s1'],
        ),
      ],
    );
    await tester.pumpWidget(_host(repos: [repo], sessions: [_session()]));
    await tester.pump();

    expect(find.text('3 files uncommitted'), findsOneWidget);
    expect(find.text('#42 · 3 files uncommitted'), findsNothing);
  });

  testWidgets('a merged PR advertises its own clean-up', (tester) async {
    final repo = _repo(
      worktrees: [
        const Worktree(
          id: '/wt/feature',
          path: '/wt/feature',
          branch: 'add-login',
          isPrimary: false,
          insertions: 10,
          deletions: 0,
          filesChanged: 1,
          sessionIds: ['s1'],
          pr: PullRequest(
            number: 42,
            url: 'https://x/pull/42',
            state: 'MERGED',
            title: 'Add login',
            isDraft: false,
          ),
        ),
      ],
    );
    await tester.pumpWidget(_host(repos: [repo], sessions: [_session()]));
    await tester.pump();

    // The ending is now stated on the row, one tap from "Wrap up", instead of
    // being a purple hue you had to learn and a long-press you had to discover.
    expect(find.text('#42 · merged'), findsOneWidget);
    // A merged PR is not an open one: the repo card must not advertise it.
    // The count renders as a bare `1` under this key, so asserting on the string
    // `1 PR` passed whether or not an ended PR was counted as open.
    expect(find.byKey(const Key('openPrCount')), findsNothing);
    // The label takes the AA-safe purple. The chip tints dot and text with one
    // colour, so that variant is now the only merged hue on the row rather than
    // a pairing (vivid icon + AA-safe label) that had to be kept in step.
    final label = find.text('#42 · merged');
    expect(
      tester.widget<Text>(label).style?.color,
      Theme.of(tester.element(label)).colorScheme.prMergedText,
    );
  });

  testWidgets('a closed PR reads as closed, in words', (tester) async {
    final repo = _repo(
      worktrees: [
        const Worktree(
          id: '/wt/feature',
          path: '/wt/feature',
          branch: 'add-login',
          isPrimary: false,
          insertions: 10,
          deletions: 0,
          filesChanged: 1,
          sessionIds: ['s1'],
          pr: PullRequest(
            number: 42,
            url: 'https://x/pull/42',
            state: 'CLOSED',
            title: 'Add login',
            isDraft: false,
          ),
        ),
      ],
    );
    await tester.pumpWidget(_host(repos: [repo], sessions: [_session()]));
    await tester.pump();

    expect(find.text('#42 · closed without merging'), findsOneWidget);
    // The count renders as a bare `1` under this key, so asserting on the string
    // `1 PR` passed whether or not an ended PR was counted as open.
    expect(find.byKey(const Key('openPrCount')), findsNothing);
  });

  testWidgets('a session under its worktree surfaces its status as a dot', (
    tester,
  ) async {
    final repo = _repo(
      worktrees: [
        const Worktree(
          id: '/wt/feature',
          path: '/wt/feature',
          branch: 'add-login',
          isPrimary: false,
          insertions: 1,
          deletions: 0,
          filesChanged: 1,
          sessionIds: ['s1'],
        ),
      ],
    );
    await tester.pumpWidget(
      _host(
        repos: [repo],
        sessions: [_session(status: SessionStatus.running)],
      ),
    );
    await tester.pump();

    // Same as the desktop sidebar: progress states are the dot's job, so the
    // word "running" is not also spelled out. The tooltip/semantics keep it
    // from being a colour-only signal.
    expect(find.text('running'), findsNothing);
    expect(find.byTooltip('running'), findsOneWidget);
  });

  testWidgets('a pending session shows in a Drafts section with a draft tag', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        repos: [_repo()],
        sessions: [_session(id: 's1', pending: true, title: '')],
      ),
    );
    await tester.pump();

    expect(find.text('DRAFTS'), findsOneWidget);
    expect(find.text('draft'), findsOneWidget);
    expect(find.text('new session'), findsWidgets);
  });

  testWidgets('known agent renders its logo, not a letter avatar', (
    tester,
  ) async {
    final repo = _repo(
      worktrees: [
        const Worktree(
          id: '/wt/f',
          path: '/wt/f',
          branch: 'b',
          isPrimary: false,
          insertions: 1,
          deletions: 0,
          filesChanged: 1,
          sessionIds: ['s1'],
        ),
      ],
    );
    await tester.pumpWidget(_host(repos: [repo], sessions: [_session()]));
    await tester.pumpAndSettle();

    expect(find.byType(SvgPicture), findsOneWidget);
    expect(find.byType(CircleAvatar), findsNothing);
  });

  testWidgets('repo menu holds New session, Resume session, Remove', (
    tester,
  ) async {
    await tester.pumpWidget(_host(repos: [_repo()], sessions: const []));
    await tester.pump();

    expect(find.text('Resume session'), findsNothing);

    await tester.tap(find.byTooltip('Repo actions'));
    await tester.pumpAndSettle();

    expect(find.text('New session'), findsWidgets);
    expect(find.text('Resume session'), findsOneWidget);
    expect(find.text('Remove from makit'), findsOneWidget);
  });
}
