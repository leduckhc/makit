import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/status/activity_view.dart';
import 'package:makit/status/status_center.dart';
import 'package:makit/status/status_providers.dart';

void main() {
  late StatusCenter center;
  final copied = <String>[];

  setUp(() {
    center = StatusCenter();
    copied.clear();
  });
  tearDown(() => center.dispose());

  void mockClipboard(WidgetTester t) {
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => t.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
  }

  Future<void> pumpView(
    WidgetTester t, {
    void Function(String sessionId)? onOpenSession,
  }) async {
    await t.pumpWidget(
      ProviderScope(
        overrides: [statusCenterProvider.overrideWithValue(center)],
        child: MaterialApp(
          theme: makitLightTheme,
          home: Scaffold(body: ActivityView(onOpenSession: onOpenSession)),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  testWidgets('lists events newest first', (t) async {
    center.info('older', source: 'ports');
    center.failure('newer', source: 'worktree');
    await pumpView(t);
    final titles = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data)
        .whereType<String>()
        .where((s) => s == 'older' || s == 'newer')
        .toList();
    expect(titles, ['newer', 'older']);
  });

  testWidgets('an empty center says so instead of showing a blank list',
      (t) async {
    await pumpView(t);
    expect(find.textContaining('Nothing yet'), findsOneWidget);
  });

  testWidgets('opening marks everything read', (t) async {
    center.failure('Rename failed', source: 'worktree');
    expect(center.unreadCount, 1);
    await pumpView(t);
    expect(center.unreadCount, 0);
  });

  testWidgets('a live event appears without a reopen', (t) async {
    await pumpView(t);
    center.success('Created feat/x', source: 'worktree');
    await t.pumpAndSettle();
    expect(find.text('Created feat/x'), findsOneWidget);
  });

  testWidgets('the detail is hidden until you ask, then selectable', (t) async {
    center.failure(
      'Could not create worktree',
      detail: 'FileSystemException: File exists, errno = 17',
      source: 'worktree',
    );
    await pumpView(t);
    expect(find.textContaining('errno = 17'), findsNothing);
    await t.tap(find.text('Could not create worktree'));
    await t.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.textContaining('errno = 17'), findsOneWidget);
  });

  testWidgets('a row without detail does not pretend to expand', (t) async {
    center.success('Paired!', source: 'pairing');
    await pumpView(t);
    await t.tap(find.text('Paired!'));
    await t.pumpAndSettle();
    expect(find.byType(SelectableText), findsNothing);
  });

  testWidgets('copy one row copies the whole record', (t) async {
    mockClipboard(t);
    center.failure('Pair failed', detail: 'SocketException', source: 'pairing');
    await pumpView(t);
    await t.tap(find.text('Pair failed'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Copy this entry'));
    await t.pumpAndSettle();
    expect(copied.single, contains('Pair failed'));
    expect(copied.single, contains('SocketException'));
    expect(copied.single, contains('[pairing]'));
  });

  testWidgets('copy all copies every row, oldest first', (t) async {
    mockClipboard(t);
    center.info('first', source: 't');
    center.failure('second', source: 't');
    await pumpView(t);
    await t.tap(find.byTooltip('Copy all'));
    await t.pumpAndSettle();
    expect(copied.single.indexOf('first'),
        lessThan(copied.single.indexOf('second')));
  });

  testWidgets('the severity filter keeps only what is at least as loud',
      (t) async {
    center.info('a copied URL', source: 'ports');
    center.failure('a real problem', source: 'worktree');
    await pumpView(t);
    await t.tap(find.byTooltip('Filter'));
    await t.pumpAndSettle();
    await t.tap(find.text('Warnings').last);
    await t.pumpAndSettle();
    expect(find.text('a real problem'), findsOneWidget);
    expect(find.text('a copied URL'), findsNothing);
  });

  testWidgets('clear empties the record', (t) async {
    center.info('one', source: 't');
    await pumpView(t);
    await t.tap(find.byTooltip('Clear'));
    await t.pumpAndSettle();
    expect(center.events, isEmpty);
    expect(find.textContaining('Nothing yet'), findsOneWidget);
  });

  testWidgets('a session event offers a way into that session', (t) async {
    final opened = <String>[];
    center.failure('Turn failed', source: 'agent', sessionId: 's7');
    await pumpView(t, onOpenSession: opened.add);
    await t.tap(find.text('Turn failed'));
    await t.pumpAndSettle();
    await t.tap(find.text('Open session'));
    await t.pumpAndSettle();
    expect(opened, ['s7']);
  });

  testWidgets('a coalesced burst reads as one row with its count', (t) async {
    center.failure('Could not delete worktree', source: 'worktree');
    center.failure('Could not delete worktree', source: 'worktree');
    await pumpView(t);
    expect(find.text('Could not delete worktree ×2'), findsOneWidget);
  });

  testWidgets('each row shows where it came from', (t) async {
    center.failure('Boom', source: 'worktree');
    await pumpView(t);
    expect(find.text('worktree'), findsOneWidget);
  });

  group('relative time', () {
    test('reads in the units a person would say', () {
      final now = DateTime(2026, 8, 9, 12, 0, 0);
      String ago(Duration d) => activityAgo(now.subtract(d), now: now);
      expect(ago(const Duration(seconds: 3)), 'now');
      expect(ago(const Duration(seconds: 45)), '45s');
      expect(ago(const Duration(minutes: 5)), '5m');
      expect(ago(const Duration(hours: 3)), '3h');
      expect(ago(const Duration(days: 2)), '2d');
    });
  });
}
