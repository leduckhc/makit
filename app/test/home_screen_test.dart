import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:makit/app/theme.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/home/home_screen.dart';
import 'package:makit/ui/home/repo_chips.dart';
import 'package:makit/ui/widgets/glass.dart';
import 'package:makit/ui/widgets/pr_state_style.dart';

import 'support/svg_asset_finder.dart';

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
    // Matching the desktop sidebar (SPEC-11): every worktree is listed, whether
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

  testWidgets('an open PR renders a PR pill', (tester) async {
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

    expect(find.text('PR #42'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(PrPill),
        matching: find.byIcon(PhosphorIconsLight.gitPullRequest),
      ),
      findsOneWidget,
    );
    // The repo card's meta row counts it as one *open* PR.
    expect(find.text('1 PR'), findsOneWidget);
  });

  testWidgets('a merged PR pill reads as merged, not as a live PR', (
    tester,
  ) async {
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

    final icon = find.descendant(
      of: find.byType(PrPill),
      matching: find.byIcon(PhosphorIconsLight.gitMerge),
    );
    expect(icon, findsOneWidget);
    expect(find.byIcon(PhosphorIconsLight.gitPullRequest), findsNothing);
    // A merged PR is not an open one: the repo card must not advertise it.
    expect(find.text('1 PR'), findsNothing);
    expect(tester.widget<Icon>(icon).color, kPrMerged);
    // The label takes the AA-safe purple, not the vivid icon hue.
    expect(
      tester.widget<Text>(find.text('PR #42')).style?.color,
      Theme.of(tester.element(icon)).colorScheme.prMergedText,
    );
  });

  testWidgets('a closed PR pill reads as closed', (tester) async {
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

    expect(
      find.descendant(
        of: find.byType(PrPill),
        matching: findSvgAsset(kClosedPrAsset),
      ),
      findsOneWidget,
    );
    expect(find.text('1 PR'), findsNothing);
  });

  testWidgets('a session under its worktree surfaces a status chip', (
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

    expect(find.text('running'), findsOneWidget);
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

    await tester.tap(find.byIcon(PhosphorIconsRegular.dotsThreeVertical));
    await tester.pumpAndSettle();

    expect(find.text('New session'), findsWidgets);
    expect(find.text('Resume session'), findsOneWidget);
    expect(find.text('Remove from makit'), findsOneWidget);
  });
}
