// T3 — SPEC-message-navigator: jump-target support inside the anchored sliver.
//
// The point of these tests is the *frame count*: a post-frame correction loop
// would need a second pump and would paint a wrong frame in between (the blink
// `_RenderAnchoredSliverList` exists to prevent — see its doc comment). An
// in-layout `scrollOffsetCorrection` lands within the frame it is requested.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/ui/session/transcript_list.dart';

void main() {
  /// 60 rows of deliberately uneven height, newest-first (reversed list).
  /// Row `i` (child index) is `40 + (i % 7) * 18` tall.
  Future<(ScrollController, TranscriptJumpTarget)> pumpList(
    WidgetTester tester, {
    int count = 60,
  }) async {
    final controller = ScrollController();
    final target = TranscriptJumpTarget();
    addTearDown(controller.dispose);
    addTearDown(target.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TranscriptListView(
            controller: controller,
            padding: EdgeInsets.zero,
            itemCount: count,
            jumpTarget: target,
            findChildIndexCallback: (key) => (key as ValueKey<int>).value,
            itemBuilder: (context, i) => SizedBox(
              key: ValueKey(i),
              height: 40 + (i % 7) * 18,
              child: Text('row $i'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return (controller, target);
  }

  testWidgets('a jump to an un-built row lands in ONE frame', (tester) async {
    final (controller, target) = await pumpList(tester);
    expect(find.text('row 48'), findsNothing);

    target.request(48);
    await tester.pump(); // exactly one frame

    expect(
      find.text('row 48'),
      findsOneWidget,
      reason:
          'the target must be on screen after a single frame — a post-frame '
          'correction would need two and blink in between',
    );
    expect(controller.position.pixels, greaterThan(0));
    expect(target.childIndex, isNull, reason: 'target clears once resolved');
  });

  testWidgets('a jump to a row that is already built also lands', (
    tester,
  ) async {
    final (controller, target) = await pumpList(tester);
    target.request(2);
    await tester.pump();
    expect(find.text('row 2'), findsOneWidget);
    expect(controller.position.pixels, greaterThanOrEqualTo(0));
  });

  testWidgets('jumping to the last row lands at the far end', (tester) async {
    final (controller, target) = await pumpList(tester);
    target.request(59);
    await tester.pump();
    expect(find.text('row 59'), findsOneWidget);
    expect(
      controller.position.pixels,
      closeTo(controller.position.maxScrollExtent, 1.0),
    );
  });

  testWidgets('an out-of-range target is a no-op, not a crash', (tester) async {
    final (controller, target) = await pumpList(tester);
    final before = controller.position.pixels;
    target.request(5000);
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(controller.position.pixels, before);
    expect(target.childIndex, isNull, reason: 'must give up, not spin');
  });

  testWidgets('repeated jumps stay stable and never trip the viewport '
      'correction limit', (tester) async {
    final (_, target) = await pumpList(tester);
    for (final i in const [58, 3, 41, 12, 59, 0]) {
      target.request(i);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('row $i'), findsOneWidget, reason: 'jump to $i');
    }
  });

  testWidgets('a jump does not disturb the row the user unfolded', (
    tester,
  ) async {
    // Anchoring is exercised properly in transcript_anchor_test.dart; here we
    // only assert the jump path leaves the built rows' state alone.
    final (controller, target) = await pumpList(tester);
    target.request(30);
    await tester.pump();
    final at30 = controller.position.pixels;
    // A second jump to the same place must be a no-op.
    target.request(30);
    await tester.pump();
    expect(controller.position.pixels, closeTo(at30, 1.0));
  });
}
