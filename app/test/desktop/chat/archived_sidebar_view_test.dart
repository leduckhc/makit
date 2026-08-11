// SPEC-29: sidebar Active⇄Archived toggle + grouped archived view.
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/archived_sidebar_view.dart';
import 'package:makit/desktop/chat/desktop_sidebar.dart';
import 'package:makit/status/status_center.dart';
import 'package:makit/status/status_providers.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/transport/protocol.dart';

class _ArchiveConn extends ConnectionController {
  _ArchiveConn(this.archived) : super(const _NoStore());
  final List<Map<String, dynamic>> archived;
  final sent = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> request(MsgType t, Map<String, dynamic> body) {
    sent.add(body);
    if (body['kind'] == 'session.listArchived') {
      return Future.value({'sessions': archived});
    }
    return Future.value(const {});
  }
}

class _NoStore implements SecureStore {
  const _NoStore();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

// A connection whose `session.listArchived` responses are completed manually,
// so a test can observe the in-flight reload window (old rows must stay visible,
// no spinner) before the new list arrives.
class _DeferredArchiveConn extends ConnectionController {
  _DeferredArchiveConn() : super(const _NoStore());
  final pending = <Completer<Map<String, dynamic>>>[];
  @override
  Future<Map<String, dynamic>> request(MsgType t, Map<String, dynamic> body) {
    if (body['kind'] == 'session.listArchived') {
      final c = Completer<Map<String, dynamic>>();
      pending.add(c);
      return c.future;
    }
    return Future.value(const {});
  }

  void resolveLatest(List<Map<String, dynamic>> archived) =>
      pending.last.complete({'sessions': archived});
}

Map<String, dynamic> _arch(
  String id,
  String title, {
  String agent = 'pi',
  String? branch,
  bool orphaned = false,
}) => {
  'id': id,
  'projectId': 'p1',
  'agent': agent,
  'title': title,
  'status': 'exited',
  'policy': 'ask-on-risky',
  'archived': true,
  'orphaned': orphaned,
  'branch': ?branch,
};

RepoInfo _repo() => const RepoInfo(
  id: 'p1',
  name: 'makit',
  path: '/repo',
  pinned: false,
  lastActivityAt: 0,
  isGitRepo: true,
  defaultBranch: 'main',
  currentBranch: 'main',
  worktrees: [],
);

Future<_ArchiveConn> _pumpArchived(
  WidgetTester tester,
  List<Map<String, dynamic>> archived, {
  StatusCenter? statusCenter,
}) async {
  final conn = _ArchiveConn(archived);
  final container = ProviderContainer(
    overrides: [
      connectionControllerProvider.overrideWith((_) => conn),
      reposProvider.overrideWithValue(ReposState([_repo()])),
      sidebarArchivedProvider.overrideWith(
        (_) => true,
      ), // start in archived view
      if (statusCenter != null)
        statusCenterProvider.overrideWithValue(statusCenter),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: SizedBox(width: 300, child: DesktopSidebar())),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return conn;
}

void main() {
  testWidgets(
    'archived view lists sessions grouped by repo with an orphaned chip',
    (tester) async {
      await _pumpArchived(tester, [
        _arch('s1', 'Adapter resume', branch: 'feat/resume'),
        _arch(
          's2',
          'Ghostty rebuild',
          agent: 'codex',
          branch: 'feat/gh',
          orphaned: true,
        ),
      ]);

      expect(find.text('ARCHIVED'), findsOneWidget);
      expect(find.text('makit'), findsOneWidget); // repo group header
      expect(find.text('Adapter resume'), findsOneWidget);
      expect(find.text('Ghostty rebuild'), findsOneWidget);
      // The orphaned session is flagged.
      expect(find.text('worktree removed'), findsOneWidget);
      // Harness + branch chips render.
      expect(find.text('Codex'), findsOneWidget);
      expect(find.text('feat/resume'), findsOneWidget);
    },
  );

  testWidgets('empty archive shows a message', (tester) async {
    await _pumpArchived(tester, const []);
    expect(find.text('No archived sessions.'), findsOneWidget);
  });

  testWidgets('Restore sends session.unarchive', (tester) async {
    final conn = await _pumpArchived(tester, [_arch('s1', 'Adapter resume')]);
    // Hover reveals the restore button.
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('Adapter resume')));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Restore'));
    await tester.pumpAndSettle();

    final u = conn.sent.firstWhere(
      (b) => b['kind'] == 'session.unarchive',
      orElse: () => const {},
    );
    expect(u['sessionId'], 's1');
  });

  testWidgets('Restore reloads the list without surfacing an error', (
    tester,
  ) async {
    final center = StatusCenter();
    addTearDown(center.dispose);
    final conn = await _pumpArchived(tester, [
      _arch('s1', 'Adapter resume'),
    ], statusCenter: center);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('Adapter resume')));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Restore'));
    await tester.pumpAndSettle();

    // The buggy `setState(() => _future = _load())` returned a Future, whose
    // assertion was caught by _restore and recorded as a "Could not restore"
    // failure even though the unarchive succeeded. Guard against regressing.
    expect(center.events, isEmpty);
    // And the list refetches so the restored row drops out of the archive.
    final reloads = conn.sent
        .where((b) => b['kind'] == 'session.listArchived')
        .length;
    expect(reloads, greaterThanOrEqualTo(2));
  });

  testWidgets('reload keeps prior rows visible instead of flashing a spinner', (
    tester,
  ) async {
    final conn = _DeferredArchiveConn();
    final container = ProviderContainer(
      overrides: [
        connectionControllerProvider.overrideWith((_) => conn),
        reposProvider.overrideWithValue(ReposState([_repo()])),
        sidebarArchivedProvider.overrideWith((_) => true),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: SizedBox(width: 300, child: DesktopSidebar())),
        ),
      ),
    );
    // First load is in flight: no data yet, so the spinner IS shown.
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    conn.resolveLatest([_arch('s1', 'Adapter resume')]);
    await tester.pumpAndSettle();
    expect(find.text('Adapter resume'), findsOneWidget);

    // Restore triggers a reload; its listArchived stays pending.
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('Adapter resume')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Restore'));
    await tester.pump(); // unarchive resolves; reload now in flight
    await tester.pump();

    // Guards the `&& !snap.hasData` clause: mid-reload the old row stays put and
    // no spinner appears (a bare `== waiting` check would blank the list).
    expect(find.text('Adapter resume'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // Reload completes with the row gone — now it drops out.
    conn.resolveLatest(const []);
    await tester.pumpAndSettle();
    expect(find.text('Adapter resume'), findsNothing);
    expect(find.text('No archived sessions.'), findsOneWidget);
  });

  testWidgets('footer toggle flips into the archived view', (tester) async {
    final conn = _ArchiveConn(const []);
    final container = ProviderContainer(
      overrides: [
        connectionControllerProvider.overrideWith((_) => conn),
        reposProvider.overrideWithValue(ReposState([_repo()])),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: SizedBox(width: 300, child: DesktopSidebar())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(container.read(sidebarArchivedProvider), isFalse);
    await tester.tap(find.byTooltip('Show archived sessions'));
    await tester.pumpAndSettle();
    expect(container.read(sidebarArchivedProvider), isTrue);
    expect(find.text('ARCHIVED'), findsOneWidget);
  });
}
