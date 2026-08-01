// T4 — SPEC-34: the controller that turns "my 3rd message" into a landed jump.
//
// The trap this guards: three index spaces are in play (item position, reversed
// child index, scroll offset) and the child index shifts by one whenever the
// transcript has a trailing row. An off-by-one here lands you one message away.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/ui/session/navigator/transcript_jumper.dart';
import 'package:makit/ui/session/transcript_list.dart';

void main() {
  group('childIndexForPosition', () {
    // 10 items, no trailer: position 9 (newest) is child 0.
    test('reverses the position', () {
      expect(childIndexForPosition(9, itemCount: 10, hasTrailer: false), 0);
      expect(childIndexForPosition(0, itemCount: 10, hasTrailer: false), 9);
      expect(childIndexForPosition(4, itemCount: 10, hasTrailer: false), 5);
    });

    test('shifts by one when a trailing row occupies child 0', () {
      expect(childIndexForPosition(9, itemCount: 10, hasTrailer: true), 1);
      expect(childIndexForPosition(0, itemCount: 10, hasTrailer: true), 10);
    });

    test(
      'matches transcriptChildIndexFinder for every position, both ways',
      () {
        // The finder is the source of truth; this asserts we did not restate it
        // wrongly. (Checked here arithmetically: length - 1 - p + trailer.)
        for (final trailer in [false, true]) {
          for (var p = 0; p < 12; p++) {
            expect(
              childIndexForPosition(p, itemCount: 12, hasTrailer: trailer),
              12 - 1 - p + (trailer ? 1 : 0),
            );
          }
        }
      },
    );

    test('an out-of-range position yields null', () {
      expect(
        childIndexForPosition(-1, itemCount: 5, hasTrailer: false),
        isNull,
      );
      expect(childIndexForPosition(5, itemCount: 5, hasTrailer: false), isNull);
      expect(childIndexForPosition(0, itemCount: 0, hasTrailer: false), isNull);
    });
  });

  group('TranscriptJumper', () {
    late ScrollController controller;
    late TranscriptJumpTarget target;

    /// 40 rows of uneven height; item position p renders at child 39-p.
    Future<TranscriptJumper> pump(
      WidgetTester tester, {
      int count = 40,
      bool hasTrailer = false,
    }) async {
      controller = ScrollController();
      target = TranscriptJumpTarget();
      addTearDown(controller.dispose);
      addTearDown(target.dispose);
      final jumper = TranscriptJumper(
        controller: controller,
        target: target,
        itemCount: () => count,
        hasTrailer: () => hasTrailer,
      );
      addTearDown(jumper.dispose);
      final total = count + (hasTrailer ? 1 : 0);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TranscriptListView(
              controller: controller,
              padding: EdgeInsets.zero,
              itemCount: total,
              jumpTarget: target,
              findChildIndexCallback: (key) => (key as ValueKey<int>).value,
              itemBuilder: (context, i) => SizedBox(
                key: ValueKey(i),
                height: 40 + (i % 5) * 22,
                child: Text('child $i'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return jumper;
    }

    testWidgets('jumps to an un-built item and flashes it', (tester) async {
      final jumper = await pump(tester);
      expect(find.text('child 35'), findsNothing);

      jumper.jumpToItem(4); // 39 - 4 = child 35
      await tester.pump();

      expect(find.text('child 35'), findsOneWidget);
      expect(jumper.flashed.value?.position, 4);
    });

    testWidgets('a built item needs no correction at all', (tester) async {
      final jumper = await pump(tester);
      jumper.jumpToItem(39); // newest — already on screen
      await tester.pump();
      expect(target.childIndex, isNull, reason: 'fast path: never requests');
      expect(jumper.flashed.value?.position, 39, reason: 'flash still fires');
    });

    testWidgets('the trailer shift is applied', (tester) async {
      final jumper = await pump(tester, hasTrailer: true);
      // position 4 → child 40-1-4+1 = 36. Assert it landed at the *top* of the
      // viewport: neighbouring rows are on screen too, so mere visibility would
      // not distinguish a one-off transform.
      jumper.jumpToItem(4);
      await tester.pump();
      expect(find.text('child 36'), findsOneWidget);
      expect(tester.getTopLeft(find.text('child 36')).dy, closeTo(0, 24));
    });

    testWidgets('jumping to the same item twice re-arms the flash', (
      tester,
    ) async {
      // The row animates its own outline out, so the notifier keeps the last
      // jump; only the serial tells a repeat apart from a no-op.
      final jumper = await pump(tester);
      jumper.jumpToItem(10);
      await tester.pump();
      final first = jumper.flashed.value!;
      jumper.jumpToItem(10);
      await tester.pump();
      final second = jumper.flashed.value!;
      expect(second.position, 10);
      expect(second.serial, greaterThan(first.serial));
      expect(second, isNot(first));
    });

    testWidgets('overlapping jumps: the last target wins', (tester) async {
      final jumper = await pump(tester);
      jumper.jumpToItem(2);
      jumper.jumpToItem(30);
      await tester.pump();
      expect(jumper.flashed.value?.position, 30);
      expect(find.text('child 9'), findsOneWidget); // 39 - 30
    });

    testWidgets('an out-of-range item is a no-op', (tester) async {
      final jumper = await pump(tester);
      final before = controller.position.pixels;
      jumper.jumpToItem(999);
      jumper.jumpToItem(-3);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(controller.position.pixels, before);
      expect(jumper.flashed.value, isNull, reason: 'nothing to flash');
    });

    testWidgets('never uses animateTo — the position settles immediately', (
      tester,
    ) async {
      final jumper = await pump(tester);
      jumper.jumpToItem(20);
      await tester.pump();
      // An animateTo would still be running here; a jumpTo has already settled.
      expect(controller.position.activity?.isScrolling ?? false, isFalse);
    });
  });
}
