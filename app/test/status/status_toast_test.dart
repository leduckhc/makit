import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/status/status_center.dart';
import 'package:makit/status/status_event.dart';
import 'package:makit/status/status_providers.dart';
import 'package:makit/status/status_toast.dart';

void main() {
  late StatusCenter center;

  setUp(() => center = StatusCenter());
  tearDown(() => center.dispose());

  Future<void> pumpLayer(
    WidgetTester tester, {
    void Function(StatusEvent?)? onOpen,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [statusCenterProvider.overrideWithValue(center)],
        child: MaterialApp(
          theme: makitLightTheme,
          home: StatusToastLayer(
            onOpen: onOpen,
            child: const Scaffold(body: Text('content')),
          ),
        ),
      ),
    );
  }

  /// Captures every `Clipboard.setData` payload written during a test.
  List<String> watchClipboard(WidgetTester tester) {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    return copied;
  }

  testWidgets('a posted event shows a toast carrying its title', (t) async {
    await pumpLayer(t);
    center.failure(
      'Could not create worktree',
      error: StateError('errno 17'),
      source: 'worktree',
    );
    await t.pump();
    expect(find.text('Could not create worktree'), findsOneWidget);
    // The detail is previewed, not hidden behind a tap.
    expect(find.textContaining('errno 17'), findsOneWidget);
  });

  testWidgets('the toast leaves on its own dwell and the record survives it', (
    t,
  ) async {
    await pumpLayer(t);
    center.info('URL copied', source: 'ports');
    await t.pump();
    expect(find.text('URL copied'), findsOneWidget);
    await t.pump(const Duration(seconds: 3));
    await t.pumpAndSettle();
    expect(find.text('URL copied'), findsNothing);
    expect(center.events.single.title, 'URL copied');
  });

  testWidgets('a failure lingers longer than an info', (t) async {
    await pumpLayer(t);
    center.failure('Rename failed', source: 'worktree');
    await t.pump();
    await t.pump(const Duration(seconds: 4));
    expect(find.text('Rename failed'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));
    await t.pumpAndSettle();
    expect(find.text('Rename failed'), findsNothing);
  });

  testWidgets('dismissing a toast keeps the event on the record', (t) async {
    await pumpLayer(t);
    center.warning('Port still listening', source: 'ports');
    await t.pump();
    await t.tap(find.byTooltip('Dismiss'));
    await t.pumpAndSettle();
    expect(find.text('Port still listening'), findsNothing);
    expect(center.events, hasLength(1));
  });

  testWidgets('a coalesced repeat updates one toast instead of stacking', (
    t,
  ) async {
    await pumpLayer(t);
    center.failure('Could not delete worktree', source: 'worktree');
    await t.pump();
    center.failure('Could not delete worktree', source: 'worktree');
    center.failure('Could not delete worktree', source: 'worktree');
    // Two pumps: the change stream hands over one batch per frame.
    await t.pump();
    await t.pump();
    expect(find.text('Could not delete worktree ×3'), findsOneWidget);
    expect(find.byType(StatusToastCard), findsOneWidget);
  });

  testWidgets('at most three toasts show, the rest wait behind a +N chip', (
    t,
  ) async {
    await pumpLayer(t);
    for (var i = 0; i < 5; i++) {
      center.failure('Failure $i', source: 't$i');
    }
    for (var i = 0; i < 5; i++) {
      await t.pump();
    }
    expect(find.byType(StatusToastCard), findsNWidgets(3));
    expect(find.text('+2 more'), findsOneWidget);
  });

  testWidgets('copy puts the full record on the clipboard, detail included', (
    t,
  ) async {
    final copied = watchClipboard(t);
    await pumpLayer(t);
    center.failure(
      'Pair failed',
      detail: 'SocketException: refused',
      source: 'pairing',
    );
    await t.pump();
    await t.tap(find.text('Pair failed'));
    await t.pumpAndSettle();
    expect(copied.single, contains('Pair failed'));
    expect(copied.single, contains('SocketException: refused'));
  });

  // SPEC-notice-layer D1: this used to assert the opposite — that an event with no
  // `detail` had no copy affordance at all. That gate was the sharpest instance
  // of "it is impossible to copy": the head line is still the thing a person
  // wants to paste.
  testWidgets('every notice can be copied, detail or not', (t) async {
    final copied = watchClipboard(t);
    await pumpLayer(t);
    center.success('Paired!', source: 'pairing');
    await t.pump();
    await t.tap(find.text('Paired!'));
    await t.pumpAndSettle();
    expect(copied.single, contains('Paired!'));
    expect(copied.single, center.events.single.toClipboardText());
  });

  testWidgets('tapping the body copies the whole record, verbatim', (t) async {
    final copied = watchClipboard(t);
    await pumpLayer(t);
    center.failure(
      'Pair failed',
      detail: 'SocketException: refused',
      source: 'pairing',
    );
    await t.pump();
    await t.tap(find.text('Pair failed'));
    await t.pumpAndSettle();
    expect(copied.single, center.events.single.toClipboardText());
    expect(copied.single, contains('SocketException: refused'));
  });

  testWidgets('copying confirms in place, reverts, and posts nothing', (
    t,
  ) async {
    watchClipboard(t);
    await pumpLayer(t);
    center.failure('Rename failed', source: 'worktree');
    await t.pump();
    final before = center.events.length;
    await t.tap(find.text('Rename failed'));
    await t.pump();
    // In place: the card says so itself rather than posting a notice about the
    // notice (SPEC-notice-layer D6).
    expect(find.text('Copied'), findsOneWidget);
    expect(center.events, hasLength(before));
    await t.pump(const Duration(milliseconds: 1300));
    expect(find.text('Copied'), findsNothing);
    expect(find.text('Rename failed'), findsOneWidget);
  });

  testWidgets('a secondary click never copies', (t) async {
    final copied = watchClipboard(t);
    await pumpLayer(t);
    center.failure('Turn failed', source: 'agent');
    await t.pump();
    final g = await t.startGesture(
      t.getCenter(find.byType(StatusToastCard)),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await g.up();
    await t.pumpAndSettle();
    expect(copied, isEmpty);
  });

  // SPEC-notice-layer D7: this used to tap the body. Copy is the action that cannot be
  // performed any other way, so it took the body; opening keeps an explicit
  // control.
  testWidgets('the open control hands the event to onOpen without copying', (
    t,
  ) async {
    final copied = watchClipboard(t);
    final opened = <StatusEvent?>[];
    await pumpLayer(t, onOpen: opened.add);
    center.failure('Turn failed', source: 'agent', sessionId: 's1');
    await t.pump();
    await t.tap(find.byTooltip('Open'));
    await t.pumpAndSettle();
    expect(opened.single?.sessionId, 's1');
    expect(copied, isEmpty);
  });

  testWidgets('there is no open control when there is nowhere to go', (
    t,
  ) async {
    await pumpLayer(t);
    center.failure('Turn failed', source: 'agent');
    await t.pump();
    expect(find.byTooltip('Open'), findsNothing);
  });

  testWidgets('a silent post never becomes a toast', (t) async {
    await pumpLayer(t);
    center.success(
      'Agent finished its turn',
      source: 'agent',
      sessionId: 's1',
      silent: true,
    );
    await t.pump();
    await t.pump();
    expect(find.byType(StatusToastCard), findsNothing);
    expect(center.events, hasLength(1));
  });

  testWidgets('reading the inbox clears the toasts it duplicates', (t) async {
    await pumpLayer(t);
    center.failure('Rename failed', source: 'worktree');
    await t.pump();
    center.markAllRead();
    await t.pumpAndSettle();
    expect(find.byType(StatusToastCard), findsNothing);
  });

  // ── SPEC-notice-layer D2: reachable without a pointer ──────────────────────────────

  testWidgets('the card takes keyboard focus and Enter copies it', (t) async {
    final copied = watchClipboard(t);
    await pumpLayer(t);
    center.failure('Rename failed', source: 'worktree');
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pumpAndSettle();
    expect(copied.single, center.events.single.toClipboardText());
  });

  testWidgets('Space copies too', (t) async {
    final copied = watchClipboard(t);
    await pumpLayer(t);
    center.failure('Rename failed', source: 'worktree');
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.space);
    await t.pumpAndSettle();
    expect(copied, hasLength(1));
  });

  testWidgets('a screen reader is offered a named copy action', (t) async {
    final handle = t.ensureSemantics();
    // `finally`, not `addTearDown`: Flutter verifies that every SemanticsHandle
    // was disposed at the end of the test BODY, before tear-downs run — so a
    // tear-down is too late and fails the test on its way out. This still meets
    // the point of registering early: a failing expectation below cannot leave
    // semantics enabled for the rest of the file and break later tests for an
    // unrelated reason.
    try {
      await pumpLayer(t);
      center.failure('Rename failed', source: 'worktree');
      await t.pump();
      expect(
        t.getSemantics(find.byType(StatusToastCard)),
        isSemantics(
          customActions: <CustomSemanticsAction>[
            const CustomSemanticsAction(label: 'Copy'),
          ],
        ),
        reason:
            'the copy action must be reachable by assistive tech, not only '
            'by pointer (SPEC-notice-layer D2)',
      );
    } finally {
      handle.dispose();
    }
  });

  // ── SPEC-notice-layer D4: attention pauses the dwell ───────────────────────────────

  testWidgets('hovering holds the notice past its dwell', (t) async {
    await pumpLayer(t);
    center.info('URL copied', source: 'ports');
    await t.pump();
    final g = await t.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: Offset.zero);
    addTearDown(g.removePointer);
    await g.moveTo(t.getCenter(find.byType(StatusToastCard)));
    // The enter must be processed on a frame before time advances, or the
    // pending dwell timer fires first.
    await t.pump();
    await t.pump(const Duration(seconds: 4));
    expect(find.text('URL copied'), findsOneWidget);
  });

  testWidgets('a coalesced repeat does not dismiss a notice you are holding', (
    t,
  ) async {
    // The layer restarts the dwell on every post, which is right for a repeat
    // that bumped the count — but not while the pointer is on the card. That
    // timer used to dismiss the notice being read or copied, defeating D4.
    await pumpLayer(t);
    center.info('URL copied', source: 'ports');
    await t.pump();
    final g = await t.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: Offset.zero);
    addTearDown(g.removePointer);
    await g.moveTo(t.getCenter(find.byType(StatusToastCard)));
    await t.pump();

    // Same event again: coalesces into the held card, whose title now carries
    // the count — which also proves the repeat landed rather than being dropped.
    center.info('URL copied', source: 'ports');
    await t.pump();
    await t.pump(const Duration(seconds: 4));

    expect(
      find.text('URL copied ×2'),
      findsOneWidget,
      reason: 'the hold outranks the repeat',
    );
  });

  testWidgets('leaving restarts the whole dwell, not the remainder', (t) async {
    await pumpLayer(t);
    center.info('URL copied', source: 'ports');
    await t.pump();
    final g = await t.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: Offset.zero);
    addTearDown(g.removePointer);
    await g.moveTo(t.getCenter(find.byType(StatusToastCard)));
    await t.pump();
    await t.pump(const Duration(seconds: 2));
    await g.moveTo(const Offset(5, 5));
    await t.pump();
    // A remainder-based implementation would already be gone here.
    await t.pump(const Duration(milliseconds: 2900));
    expect(find.text('URL copied'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 200));
    await t.pumpAndSettle();
    expect(find.text('URL copied'), findsNothing);
  });

  testWidgets('a hover has no expiry cap: it holds while you hold it', (
    t,
  ) async {
    await pumpLayer(t);
    center.info('URL copied', source: 'ports');
    await t.pump();
    final g = await t.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: Offset.zero);
    addTearDown(g.removePointer);
    await g.moveTo(t.getCenter(find.byType(StatusToastCard)));
    await t.pump();
    await t.pump(const Duration(seconds: 40));
    expect(find.text('URL copied'), findsOneWidget);
  });

  // ── SPEC-notice-layer D5: contact shows the whole payload ──────────────────────────

  testWidgets('hovering unfolds the whole detail, selectably', (t) async {
    await pumpLayer(t);
    center.failure(
      'Could not create worktree',
      detail:
          'FileSystemException: Creation failed\n'
          "path = '/Users/le/.worktrees/makit/x'\n"
          '(OS Error: File exists, errno = 17)',
      source: 'worktree',
    );
    await t.pump();
    // Collapsed: only the first line is previewed.
    expect(find.textContaining('errno = 17'), findsNothing);
    final g = await t.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: Offset.zero);
    addTearDown(g.removePointer);
    await g.moveTo(t.getCenter(find.byType(StatusToastCard)));
    await t.pump();
    // Expanded: the tail a one-line preview can never show.
    expect(find.textContaining('errno = 17'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
    await g.moveTo(const Offset(5, 5));
    await t.pump();
    expect(find.textContaining('errno = 17'), findsNothing);
  });

  // ── SPEC-notice-layer D4/D7: one gesture, one meaning ──────────────────────────────

  testWidgets('a touch tap copies without unfolding or pausing', (t) async {
    final copied = watchClipboard(t);
    await pumpLayer(t);
    center.failure('Rename failed', detail: 'errno 17', source: 'worktree');
    await t.pump();
    await t.tap(find.byType(StatusToastCard));
    await t.pump();
    expect(copied, hasLength(1));
    // A touch has no hover, so it must not also enter the read state.
    expect(find.byType(SelectableText), findsNothing);
    // And the dwell must still be running.
    await t.pump(const Duration(seconds: 9));
    await t.pumpAndSettle();
    expect(find.byType(StatusToastCard), findsNothing);
  });

  testWidgets('hovering never copies on its own', (t) async {
    final copied = watchClipboard(t);
    await pumpLayer(t);
    center.failure('Rename failed', source: 'worktree');
    await t.pump();
    final g = await t.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: Offset.zero);
    addTearDown(g.removePointer);
    await g.moveTo(t.getCenter(find.byType(StatusToastCard)));
    await t.pump();
    expect(copied, isEmpty);
  });
}
