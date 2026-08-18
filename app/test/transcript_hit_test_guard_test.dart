// A tap must never crash on a row the last layout did not position.
//
// The desktop app logged this 49 times across two log files:
//
//   Null check operator used on a null value (while handling a pointer data packet)
//   #0 RenderSliverMultiBoxAdaptor.childMainAxisPosition
//   #1 RenderSliverHelpers.hitTestBoxChild
//   #2 RenderSliverMultiBoxAdaptor.hitTestChildren
//
// `childMainAxisPosition` is `childScrollOffset(child)! - scrollOffset`, so it
// throws for a child whose `layoutOffset` is null. A lazy sliver leaves a child
// unpositioned when its layout ended on a `scrollOffsetCorrection` that the
// viewport ran out of cycles to settle — and the transcript issues corrections
// itself, to hold the row the user is reading in place.
//
// Two changes: the anchor stops correcting after a bounded number of attempts per
// frame (so it cannot exhaust the viewport's budget), and the hit test skips a
// child with no layout offset instead of throwing on it.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/ui/session/transcript_list.dart';

void main() {
  testWidgets('a tap on an unpositioned row is ignored, not fatal', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final tapped = <int>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TranscriptListView(
            controller: controller,
            padding: EdgeInsets.zero,
            itemCount: 20,
            findChildIndexCallback: (key) =>
                key is ValueKey<int> ? key.value : null,
            itemBuilder: (context, i) => KeyedSubtree(
              key: ValueKey<int>(i),
              child: GestureDetector(
                onTap: () => tapped.add(i),
                child: SizedBox(height: 80, child: Text('row $i')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // The state the crash needs: a built child that the last layout left
    // without a position. Reproduced directly, because the layout-cycle
    // exhaustion that causes it in the field depends on timing.
    final sliver = tester.renderObject<RenderSliverList>(
      find.byWidgetPredicate((w) => w is SliverList),
    );
    var stripped = 0;
    sliver.visitChildren((child) {
      final data = child.parentData! as SliverMultiBoxAdaptorParentData;
      if (data.layoutOffset != null) {
        data.layoutOffset = null;
        stripped++;
      }
    });
    expect(stripped, greaterThan(0), reason: 'the test needs a built child');

    // Before the fix this threw a null check while handling the pointer packet.
    await tester.tapAt(const Offset(200, 300));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('a positioned row still takes its taps', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final tapped = <int>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TranscriptListView(
            controller: controller,
            padding: EdgeInsets.zero,
            itemCount: 20,
            findChildIndexCallback: (key) =>
                key is ValueKey<int> ? key.value : null,
            itemBuilder: (context, i) => KeyedSubtree(
              key: ValueKey<int>(i),
              child: GestureDetector(
                onTap: () => tapped.add(i),
                child: SizedBox(height: 80, child: Text('row $i')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('row 0'));
    await tester.pump();

    expect(tapped, [0], reason: 'the guard must not swallow a real tap');
  });
}
