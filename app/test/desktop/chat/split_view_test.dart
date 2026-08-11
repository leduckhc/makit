// Widget tests for SplitView's visual states: the focused-pane tonal surface
// (light + dark themes), the focused split's active-tab cap, full-height tab
// chips, and inactive-tab dimming. Runs headless with fake sessions, like
// split_tree_view_test.dart.
//
// ignore_for_file: depend_on_referenced_packages
import 'package:flutter/material.dart' hide Tab, Split;
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/groups/agent_picker.dart';
import 'package:makit/desktop/chat/groups/group.dart';
import 'package:makit/desktop/chat/groups/groups_controller.dart';
import 'package:makit/desktop/chat/panes/split_node.dart';
import 'package:makit/desktop/chat/panes/workspace_controller.dart';
import 'package:makit/desktop/chat/split_tree_view.dart';
import 'package:makit/desktop/chat/split_view.dart';
import 'package:makit/desktop/chat/worktree_starter.dart';
import 'package:makit/store/elicitation.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';

const _model = ModelInfo(provider: 'openai', id: 'gpt-5', name: 'GPT-5');

Session _session(
  String id,
  String title, {
  String worktreePath = '/tmp/wt-a',
}) => Session(
  id: id,
  projectId: 'p1',
  agent: 'pi',
  title: title,
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
  lastPreview: '',
  lastActivityAt: 0,
  worktreePath: worktreePath,
  branch: worktreePath.split('/').last,
);

ProviderContainer _container({
  List<Session> sessions = const [],
  bool freeTextAsks = false,
}) {
  return ProviderContainer(
    // An inferred list literal, not a `List<Override>` helper: Riverpod does
    // not export the `Override` base type.
    overrides: [
      sessionsProvider.overrideWithValue(SessionsState(sessions)),
      eventsProvider.overrideWithValue(EventsState(const {}, const {})),
      for (final s in sessions)
        sessionMetaProvider(s.id).overrideWithValue(
          const SessionMeta(
            model: _model,
            thinking: 'medium',
            models: [_model],
          ),
        ),
      // One free-text ask per session — the state that swaps each pane's
      // normal composer for the dedicated answer composer.
      if (freeTextAsks)
        elicitationControllerProvider.overrideWith((ref) {
          final c = ElicitationController(
            respond: (_, _) {},
            responded: const Stream<String>.empty(),
          );
          for (final s in sessions) {
            c.add(
              PendingAsk(
                requestId: 'r-${s.id}',
                sessionId: s.id,
                questions: const [],
                freeText: true,
              ),
            );
          }
          return c;
        }),
    ],
  );
}

WorkspaceController _ws(ProviderContainer c) =>
    c.read(workspaceControllerProvider.notifier);

Widget _tree(ProviderContainer c, {Brightness brightness = Brightness.light}) =>
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.green,
            brightness: brightness,
          ),
        ),
        home: const Scaffold(body: WorkspaceView()),
      ),
    );

/// Pumps two side-by-side splits: pane A hosts s1 "Alpha", pane B hosts s2
/// "Beta". Pane B is the active (focused) split afterwards.
Future<ProviderContainer> _twoPanes(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  bool freeTextAsks = false,
}) async {
  final c = _container(
    sessions: [_session('s1', 'Alpha'), _session('s2', 'Beta')],
    freeTextAsks: freeTextAsks,
  );
  addTearDown(c.dispose);
  _ws(c).revealSession('s1'); // pane A: s1
  _ws(c).divideActive(Axis.horizontal); // pane B (empty) active
  _ws(c).revealSession('s2'); // pane B: s2
  await tester.pumpWidget(_tree(c, brightness: brightness));
  await tester.pumpAndSettle();
  return c;
}

/// The body-background colour of the pane hosting the tab labelled [label]:
/// the outermost Container of that tab's SplitView.
Color? _paneColor(WidgetTester tester, String label) {
  final pane = find.ancestor(
    of: find.text(label),
    matching: find.byType(SplitView),
  );
  return tester
      .widget<Container>(
        find.descendant(of: pane, matching: find.byType(Container)).first,
      )
      .color;
}

/// The tab chip Container for the tab labelled [label] (its decoration carries
/// the cap border; its size is the rendered chip extent).
Finder _chip(WidgetTester tester, String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(Container)).first;

/// The chip's painted surface: the chip is now a ClipRRect > Container > Column
/// (rounded tops forbid a partial border), so the surface is the innermost
/// ancestor Container that actually paints a colour.
Container _chipSurface(WidgetTester tester, String label) => tester
    .widgetList<Container>(
      find.ancestor(of: find.text(label), matching: find.byType(Container)),
    )
    .firstWhere((c) => c.color != null);

/// The composer field of the pane hosting the tab labelled [label].
Finder _composerFinder(WidgetTester tester, String label) {
  final pane = find.ancestor(
    of: find.text(label),
    matching: find.byType(SplitView),
  );
  return find.descendant(of: pane, matching: find.byType(TextField)).first;
}

TextField _composerField(WidgetTester tester, String label) =>
    tester.widget<TextField>(_composerFinder(tester, label));

ColorScheme _scheme(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(WorkspaceView))).colorScheme;

void main() {
  setUp(resetNodeIds);

  group('pane focus surfaces', () {
    testWidgets(
      'light theme: focused pane is one step lighter than unfocused panes',
      (tester) async {
        await _twoPanes(tester); // pane B ("Beta") focused
        final cs = _scheme(tester);

        expect(_paneColor(tester, 'Beta'), cs.surface);
        expect(_paneColor(tester, 'Alpha'), cs.surfaceContainerLow);
      },
    );

    testWidgets(
      'dark theme: focused pane is still the lighter (elevated) surface',
      (tester) async {
        await _twoPanes(tester, brightness: Brightness.dark);
        final cs = _scheme(tester);

        expect(cs.brightness, Brightness.dark);
        expect(_paneColor(tester, 'Beta'), cs.surfaceContainerLow);
        expect(_paneColor(tester, 'Alpha'), cs.surface);
      },
    );

    testWidgets('activating the other split moves the focused surface to it', (
      tester,
    ) async {
      final c = await _twoPanes(tester);
      final cs = _scheme(tester);

      final alphaSplitId = findTab(
        c.read(workspaceControllerProvider).root,
        's1',
      )!.$1;
      _ws(c).setActiveSplit(alphaSplitId);
      await tester.pumpAndSettle();

      expect(_paneColor(tester, 'Alpha'), cs.surface);
      expect(_paneColor(tester, 'Beta'), cs.surfaceContainerLow);
    });
  });

  group('unfocused pane composer', () {
    testWidgets('the unfocused pane shows a 1-line composer; the focused pane '
        'keeps the full multiline form', (tester) async {
      await _twoPanes(tester); // pane B ("Beta") focused

      expect(_composerField(tester, 'Alpha').maxLines, 1);
      expect(_composerField(tester, 'Beta').maxLines, greaterThan(1));
    });

    testWidgets(
      'activating the other split moves the expanded composer to it',
      (tester) async {
        final c = await _twoPanes(tester);
        final alphaSplitId = findTab(
          c.read(workspaceControllerProvider).root,
          's1',
        )!.$1;
        _ws(c).setActiveSplit(alphaSplitId);
        await tester.pumpAndSettle();

        expect(_composerField(tester, 'Alpha').maxLines, greaterThan(1));
        expect(_composerField(tester, 'Beta').maxLines, 1);
      },
    );

    testWidgets('tapping an inactive pane\'s composer activates that split and '
        'expands it in the same gesture', (tester) async {
      final c = await _twoPanes(tester); // pane B ("Beta") focused
      final alphaSplitId = findTab(
        c.read(workspaceControllerProvider).root,
        's1',
      )!.$1;

      await tester.tap(_composerFinder(tester, 'Alpha'));
      await tester.pumpAndSettle();

      expect(c.read(workspaceControllerProvider).activeSplitId, alphaSplitId);
      expect(_composerField(tester, 'Alpha').maxLines, greaterThan(1));
      expect(_composerField(tester, 'Beta').maxLines, 1);
    });

    testWidgets('the free-text answer composer collapses in the unfocused pane '
        'too, and expands when its split is activated', (tester) async {
      final c = await _twoPanes(
        tester,
        freeTextAsks: true,
      ); // pane B ("Beta") focused

      expect(_composerField(tester, 'Alpha').maxLines, 1);
      expect(_composerField(tester, 'Beta').maxLines, greaterThan(1));

      final alphaSplitId = findTab(
        c.read(workspaceControllerProvider).root,
        's1',
      )!.$1;
      _ws(c).setActiveSplit(alphaSplitId);
      await tester.pumpAndSettle();

      expect(_composerField(tester, 'Alpha').maxLines, greaterThan(1));
      expect(_composerField(tester, 'Beta').maxLines, 1);
    });
  });

  group('tab chips', () {
    testWidgets('chips fill the tab bar\'s full height (no recessed gap)', (
      tester,
    ) async {
      await _twoPanes(tester);

      final chip = tester.getRect(_chip(tester, 'Alpha'));
      final bar = tester.getRect(
        find
            .ancestor(
              of: _chip(tester, 'Alpha'),
              matching: find.byWidgetPredicate(
                (w) =>
                    w is Container && (w.constraints?.hasTightHeight ?? false),
              ),
            )
            .first,
      );
      expect(chip.top, moreOrLessEquals(bar.top));
      expect(chip.bottom, moreOrLessEquals(bar.bottom));
    });

    testWidgets('the active tab seats on its pane surface; inactive tabs are '
        'dimmed', (tester) async {
      // One split with two tabs: s2 ("Second") active, s1 ("First") inactive.
      final c = _container(
        sessions: [_session('s1', 'First'), _session('s2', 'Second')],
      );
      addTearDown(c.dispose);
      _ws(c).revealSession('s1');
      _ws(c).revealSession('s2');
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();
      final cs = _scheme(tester);

      // Active chip uses its (focused) pane's body surface; inactive chips
      // stay transparent on the recessed bar.
      Color? chipColor(String label) => _chipSurface(tester, label).color;
      expect(chipColor('Second'), cs.surface);
      expect(chipColor('First'), Colors.transparent);

      // The inactive chip recedes behind a 0.55 opacity; the active one does
      // not.
      Iterable<double> opacitiesOf(String label) => tester
          .widgetList<Opacity>(
            find.ancestor(of: find.text(label), matching: find.byType(Opacity)),
          )
          .map((o) => o.opacity);
      expect(opacitiesOf('First'), contains(0.55));
      expect(opacitiesOf('Second'), isNot(contains(0.55)));
    });
  });

  group('tab context menu', () {
    // A single split with two tabs: s2 ("Second") active, s1 ("First")
    // inactive. The inactive tab's session pane is not built, so its label
    // appears only in the tab strip — an unambiguous right-click / long-press
    // target.
    Future<ProviderContainer> twoTabs(WidgetTester tester) async {
      final c = _container(
        sessions: [_session('s1', 'First'), _session('s2', 'Second')],
      );
      addTearDown(c.dispose);
      _ws(c).revealSession('s1');
      _ws(c).revealSession('s2');
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('right-click on a session tab opens the Rename menu', (
      tester,
    ) async {
      await twoTabs(tester);

      expect(find.text('Rename session'), findsNothing);
      await tester.tap(_chip(tester, 'First'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Rename session'), findsOneWidget);
    });

    testWidgets('long-press on a session tab opens the Rename menu', (
      tester,
    ) async {
      await twoTabs(tester);

      await tester.longPress(_chip(tester, 'First'));
      await tester.pumpAndSettle();
      expect(find.text('Rename session'), findsOneWidget);
    });

    testWidgets('selecting Rename opens the rename dialog seeded with the '
        'current title', (tester) async {
      await twoTabs(tester);

      await tester.tap(_chip(tester, 'First'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      // After right-click, the popup menu is open. Tap the Rename item.
      expect(find.text('Rename session'), findsOneWidget);
      await tester.tap(find.text('Rename session'));
      await tester.pumpAndSettle();

      // The /name client command shows a text dialog prefilled with the title.
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Rename'), findsOneWidget);
      final dialogField = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(dialogField).controller?.text, 'First');
    });

    testWidgets('the empty New tab has no context menu', (tester) async {
      final c = _container();
      addTearDown(c.dispose);
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();

      expect(find.text('New'), findsOneWidget);
      await tester.tap(_chip(tester, 'New'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Rename session'), findsNothing);
    });
  });

  group('SPEC-30 Lane 6 — the tab-strip + is group-aware (decision 13)', () {
    Group wtGroup(String path, {String? sessionId, String label = 'feat/x'}) {
      final tabId = nextNodeId(SplitNodeKind.tab);
      final splitId = nextNodeId(SplitNodeKind.split);
      return Group.worktree(
        id: 'g1',
        projectId: 'p1',
        worktreePath: path,
        label: label,
        tree: WorkspaceState(
          root: Split(
            id: splitId,
            tabs: [Tab(id: tabId, sessionId: sessionId)],
            activeTabId: tabId,
          ),
          activeSplitId: splitId,
        ),
      );
    }

    Group boardGroup(List<String> members) {
      final tabId = nextNodeId(SplitNodeKind.tab);
      final splitId = nextNodeId(SplitNodeKind.split);
      return Group.board(
        id: 'b1',
        label: 'Shipping',
        members: members,
        tree: WorkspaceState(
          root: Split(
            id: splitId,
            tabs: [
              Tab(id: tabId, sessionId: members.isEmpty ? null : members.first),
            ],
            activeTabId: tabId,
          ),
          activeSplitId: splitId,
        ),
      );
    }

    Future<ProviderContainer> pump(
      WidgetTester tester, {
      required Group group,
      List<Session> sessions = const [],
    }) async {
      final c = ProviderContainer(
        overrides: [
          sessionsProvider.overrideWithValue(SessionsState(sessions)),
          reposProvider.overrideWithValue(ReposState(const [])),
          eventsProvider.overrideWithValue(EventsState(const {}, const {})),
          agentsProvider.overrideWith((ref) async => const <AgentDescriptor>[]),
          for (final s in sessions)
            sessionMetaProvider(s.id).overrideWithValue(
              const SessionMeta(
                model: _model,
                thinking: 'medium',
                models: [_model],
              ),
            ),
          groupsControllerProvider.overrideWith(
            (ref) => GroupsController.ephemeral(
              GroupsState(groups: [group], activeGroupId: group.id),
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('a foreign drop converts, and reveals the newcomer on the new '
        'board (decision 4/14 orchestration)', (tester) async {
      // The gesture itself is not simulable here, so this exercises the seam the
      // drag target calls. It is the load-bearing part: after a conversion the
      // derived workspaceControllerProvider has been rebuilt against the freshly
      // minted board's tree, so the reveal must go through a re-read controller
      // — holding the old one would drop the tab into the group the user left.
      final c = await pump(
        tester,
        group: wtGroup('/tmp/wt-a', sessionId: 's1'),
        sessions: [
          _session('s1', 'Alpha'),
          _session('s2', 'Foreign', worktreePath: '/tmp/wt-b'),
        ],
      );
      final before = c.read(groupsControllerProvider).active;

      late GroupConversion? conversion;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (ctx, ref, _) => TextButton(
                  onPressed: () => conversion = dropSessionIntoActiveGroup(
                    ref,
                    sessionId: 's2',
                    splitId: ref
                        .read(workspaceControllerProvider)
                        .activeSplitId,
                    zone: null,
                    controller: ref.read(workspaceControllerProvider.notifier),
                  ),
                  child: const Text('drop'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('drop'));
      await tester.pumpAndSettle();

      // It converted, and said so truthfully.
      expect(conversion, isNotNull);
      expect(conversion!.from, 'feat/x');

      final groups = c.read(groupsControllerProvider);
      final board = groups.active;
      expect(board.kind, GroupKind.board);
      expect(board.id, isNot(before.id));
      expect(board.members, containsAll(['s1', 's2']));

      // The original worktree group is untouched and still reachable.
      final original = groups.groups.firstWhere((g) => g.id == before.id);
      expect(original.kind, GroupKind.worktree);
      expect(original.tree, before.tree);

      // The newcomer really is on the new board's canvas — the part that would
      // silently break if the reveal used a stale controller.
      final tabs = <String?>[];
      firstSplitWhere<bool>(c.read(workspaceControllerProvider).root, (split) {
        tabs.addAll(split.tabs.map((t) => t.sessionId));
        return null;
      });
      expect(tabs, contains('s2'));
    });

    testWidgets('a session that vanished mid-drag is not given a tab', (
      tester,
    ) async {
      // Decision 6 forbids dead tiles. The session can be closed between the
      // drag starting and the drop landing, in which case there is nothing to
      // add and nothing to show.
      final c = await pump(
        tester,
        group: boardGroup(const []),
        sessions: [_session('s1', 'Alpha')],
      );

      late GroupConversion? conversion;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (ctx, ref, _) => TextButton(
                  onPressed: () => conversion = dropSessionIntoActiveGroup(
                    ref,
                    sessionId: 'gone',
                    splitId: ref
                        .read(workspaceControllerProvider)
                        .activeSplitId,
                    zone: null,
                    controller: ref.read(workspaceControllerProvider.notifier),
                  ),
                  child: const Text('drop'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('drop'));
      await tester.pumpAndSettle();

      expect(conversion, isNull);
      expect(c.read(groupsControllerProvider).active.members, isEmpty);
      final tabs = <String?>[];
      firstSplitWhere<bool>(c.read(workspaceControllerProvider).root, (split) {
        tabs.addAll(split.tabs.map((t) => t.sessionId));
        return null;
      });
      expect(
        tabs.whereType<String>(),
        isEmpty,
        reason: 'no tab may be bound to a session the server no longer has',
      );
    });

    testWidgets('a drop onto a board adds without converting', (tester) async {
      final c = await pump(
        tester,
        group: boardGroup(const ['s1']),
        sessions: [
          _session('s1', 'Alpha'),
          _session('s2', 'Other', worktreePath: '/tmp/wt-b'),
        ],
      );
      final beforeId = c.read(groupsControllerProvider).active.id;

      late GroupConversion? conversion;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (ctx, ref, _) => TextButton(
                  onPressed: () => conversion = dropSessionIntoActiveGroup(
                    ref,
                    sessionId: 's2',
                    splitId: ref
                        .read(workspaceControllerProvider)
                        .activeSplitId,
                    zone: null,
                    controller: ref.read(workspaceControllerProvider.notifier),
                  ),
                  child: const Text('drop'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('drop'));
      await tester.pumpAndSettle();

      expect(conversion, isNull, reason: 'a board absorbs anything');
      final groups = c.read(groupsControllerProvider);
      expect(groups.active.id, beforeId, reason: 'no new group');
      expect(groups.active.members, ['s1', 's2']);
    });

    testWidgets('a worktree group + opens the in-pane starter, no dialog', (
      tester,
    ) async {
      final c = await pump(
        tester,
        group: wtGroup('/tmp/wt-a', sessionId: 's1'),
        sessions: [_session('s1', 'Alpha')],
      );

      expect(find.byType(WorktreeStarter), findsNothing);
      await tester.tap(find.byTooltip('New agent on this branch'));
      await tester.pumpAndSettle();

      // The starter appears in place; the New-session dialog never opens.
      expect(find.byType(WorktreeStarter), findsOneWidget);
      expect(find.text('New session'), findsNothing);
      // The added tab carries the group's scope as its worktree hint.
      final starter = tester.widget<WorktreeStarter>(
        find.byType(WorktreeStarter),
      );
      expect(starter.worktree.path, '/tmp/wt-a');
      // Verify the tree grew by exactly one hinted tab (added once).
      final tabs = (c.read(workspaceControllerProvider).root as Split).tabs;
      expect(tabs.length, 2);
    });

    testWidgets('a board + opens the agent picker', (tester) async {
      await pump(
        tester,
        group: boardGroup(const []),
        sessions: [_session('s1', 'Alpha')],
      );

      expect(find.byType(AgentPicker), findsNothing);
      await tester.tap(find.byTooltip('Add an agent to this board'));
      await tester.pumpAndSettle();

      expect(find.byType(AgentPicker), findsOneWidget);
      expect(find.text('Add agents to “Shipping”'), findsOneWidget);
    });
  });
}
