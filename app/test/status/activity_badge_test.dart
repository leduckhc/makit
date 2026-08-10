import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/status/activity_badge.dart';
import 'package:makit/status/activity_view.dart';
import 'package:makit/status/status_center.dart';
import 'package:makit/status/status_providers.dart';

void main() {
  late StatusCenter center;

  setUp(() => center = StatusCenter());
  tearDown(() => center.dispose());

  Future<void> pump(WidgetTester t, Widget child) async {
    await t.pumpWidget(
      ProviderScope(
        overrides: [statusCenterProvider.overrideWithValue(center)],
        child: MaterialApp(
          theme: makitLightTheme,
          home: Scaffold(body: Center(child: child)),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  group('ActivityBadge (desktop)', () {
    testWidgets('shows no count when nothing is unread', (t) async {
      await pump(t, ActivityBadge(onTap: () {}));
      expect(find.byType(ActivityCountPill), findsNothing);
      expect(find.byTooltip('Activity'), findsOneWidget);
    });

    testWidgets('counts the unread and says so in the tooltip', (t) async {
      center.failure('one', source: 'worktree');
      center.warning('two', source: 'ports');
      await pump(t, ActivityBadge(onTap: () {}));
      expect(find.text('2'), findsOneWidget);
      expect(find.byTooltip('Activity — 2 unread'), findsOneWidget);
    });

    testWidgets('caps the pill at 9+ so the bell stays a bell', (t) async {
      for (var i = 0; i < 12; i++) {
        center.info('n$i', source: 't$i');
      }
      await pump(t, ActivityBadge(onTap: () {}));
      expect(find.text('9+'), findsOneWidget);
    });

    testWidgets('a live post lights it without a rebuild from above', (
      t,
    ) async {
      await pump(t, ActivityBadge(onTap: () {}));
      expect(find.byType(ActivityCountPill), findsNothing);
      center.failure('Rename failed', source: 'worktree');
      await t.pumpAndSettle();
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('reading the record puts it out again', (t) async {
      center.failure('Rename failed', source: 'worktree');
      await pump(t, ActivityBadge(onTap: () {}));
      expect(find.text('1'), findsOneWidget);
      center.markAllRead();
      await t.pumpAndSettle();
      expect(find.byType(ActivityCountPill), findsNothing);
    });

    testWidgets('a silent post never lights it (D7)', (t) async {
      await pump(t, ActivityBadge(onTap: () {}));
      center.success('Agent finished its turn', source: 'agent', silent: true);
      await t.pumpAndSettle();
      expect(find.byType(ActivityCountPill), findsNothing);
    });

    testWidgets('the tint follows the loudest unread severity', (t) async {
      center.info('quiet', source: 't');
      await pump(t, ActivityBadge(onTap: () {}));
      final cs = makitLightTheme.colorScheme;
      Color? pillColor() {
        final box = t.widget<Container>(
          find.descendant(
            of: find.byType(ActivityCountPill),
            matching: find.byType(Container),
          ),
        );
        return (box.decoration as BoxDecoration?)?.color;
      }

      expect(pillColor(), cs.outline);
      center.failure('loud', source: 't');
      await t.pumpAndSettle();
      expect(pillColor(), cs.error);
    });
  });

  group('ActivityUnreadDot (phone)', () {
    testWidgets('hangs a count off whatever leads to Activity', (t) async {
      center.failure('Rename failed', source: 'worktree');
      await pump(
        t,
        const ActivityUnreadDot(child: Icon(Icons.settings, size: 46)),
      );
      expect(find.byType(ActivityCountPill), findsOneWidget);
      expect(find.byIcon(Icons.settings), findsOneWidget);
    });

    testWidgets('is invisible with an empty record', (t) async {
      await pump(
        t,
        const ActivityUnreadDot(child: Icon(Icons.settings, size: 46)),
      );
      expect(find.byType(ActivityCountPill), findsNothing);
    });

    testWidgets('never eats the tap meant for its child', (t) async {
      var taps = 0;
      center.failure('Rename failed', source: 'worktree');
      await pump(
        t,
        ActivityUnreadDot(
          child: IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => taps++,
          ),
        ),
      );
      await t.tap(find.byIcon(Icons.settings));
      expect(taps, 1);
    });
  });

  group('showActivityDialog (desktop container)', () {
    testWidgets('opens the one Activity list and closes again', (t) async {
      center.failure('Could not archive', detail: 'boom', source: 'session');
      late BuildContext ctx;
      await pump(
        t,
        Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox();
          },
        ),
      );
      unawaited(showActivityDialog(ctx));
      await t.pumpAndSettle();
      expect(find.byType(ActivityView), findsOneWidget);
      expect(find.text('Could not archive'), findsOneWidget);
      // Opening it is what reads the record.
      expect(center.unreadCount, 0);
      await t.tap(find.byTooltip('Close'));
      await t.pumpAndSettle();
      expect(find.byType(ActivityView), findsNothing);
    });
  });
}
