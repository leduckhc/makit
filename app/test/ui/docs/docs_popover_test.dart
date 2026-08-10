import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/docs.dart';
import 'package:makit/ui/docs/doc_row.dart';
import 'package:makit/ui/docs/docs_popover.dart';

DocInfo _doc(String relPath, {String title = 'Doc'}) => DocInfo(
  key: '/repo:$relPath',
  relPath: relPath,
  title: title,
  kind: DocKind.md,
  bytes: 10,
  modifiedAt: 0,
  worktreePath: '/repo',
);

Future<void> _pump(
  WidgetTester tester,
  List<DocInfo> docs, {
  void Function(DocInfo)? onOpen,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Center(
        child: DocsPopover(
          branch: 'feat/serving-html',
          docs: docs,
          onOpenDoc: onOpen ?? (_) {},
        ),
      ),
    ),
  ),
);

void main() {
  test('hover-open dwell is 350 ms (below the tooltip dwell)', () {
    expect(kDocsHoverOpenMs, 350);
  });

  testWidgets('a click pins the popover and lists the docs', (tester) async {
    await _pump(tester, [
      _doc('mockups/x.html', title: 'Board X'),
      _doc('docs/s.md', title: 'Spec S'),
    ]);
    expect(find.byKey(kDocsPopover), findsNothing);
    await tester.tap(find.byType(DocsGlyphAnchorTapTarget));
    await tester.pumpAndSettle();
    expect(find.byKey(kDocsPopover), findsOneWidget);
    expect(find.byType(DocRow), findsNWidgets(2));
    expect(find.text('feat/serving-html'), findsOneWidget);
  });

  testWidgets('tapping a doc row fires onOpenDoc', (tester) async {
    DocInfo? opened;
    await _pump(tester, [
      _doc('docs/s.md', title: 'Spec S'),
    ], onOpen: (d) => opened = d);
    await tester.tap(find.byType(DocsGlyphAnchorTapTarget));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DocRow).first);
    expect(opened?.relPath, 'docs/s.md');
  });

  // A repo can hold hundreds of docs (teachme has 69, this repo 143), so the
  // popover must not build a row per doc, nor grow to the window's height.
  group('search and scale', () {
    List<DocInfo> many(int n) => [
      for (var i = 0; i < n; i++) _doc('docs/note-$i.md', title: 'Note $i'),
    ];

    testWidgets('builds only the visible rows, not one per doc', (
      tester,
    ) async {
      await _pump(tester, many(200));
      await tester.tap(find.byType(DocsGlyphAnchorTapTarget));
      await tester.pumpAndSettle();
      final built = find.byType(DocRow).evaluate().length;
      expect(
        built,
        lessThan(40),
        reason: 'the list must be lazy, not 200 rows',
      );
      expect(built, greaterThan(0));
    });

    testWidgets('the search field filters by title and by path', (
      tester,
    ) async {
      await _pump(tester, [
        _doc('mockups/board.html', title: 'Board X'),
        _doc(
          'flutter/learning-records/0001-prior.md',
          title: 'Prior knowledge',
        ),
      ]);
      await tester.tap(find.byType(DocsGlyphAnchorTapTarget));
      await tester.pumpAndSettle();
      expect(find.byType(DocRow), findsNWidgets(2));

      // By title…
      await tester.enterText(find.byKey(kDocsPopoverSearch), 'prior');
      await tester.pumpAndSettle();
      expect(find.byType(DocRow), findsOneWidget);
      expect(find.text('Prior knowledge'), findsOneWidget);

      // …and by path.
      await tester.enterText(find.byKey(kDocsPopoverSearch), 'mockups/');
      await tester.pumpAndSettle();
      expect(find.byType(DocRow), findsOneWidget);
      expect(find.text('Board X'), findsOneWidget);
    });

    // The panel sized its list with `clamp(0.0, maxHeight - kChrome)`, and Dart's
    // clamp asserts lower <= upper — so a surface leaving less than the chrome
    // height of room threw ArgumentError instead of rendering. A 200pt-tall window
    // lands squarely in that range (the panel gets ~90pt, chrome wanted 96), so
    // this test throws on the old code and renders on the new.
    testWidgets('renders where the list no longer fits, instead of throwing', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400 * 3, 180 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await _pump(tester, [_doc('docs/s.md', title: 'Spec S')]);
      await tester.tap(find.byType(DocsGlyphAnchorTapTarget));
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason: 'no clamp assertion and no overflow when the list is squeezed',
      );
      expect(find.byKey(kDocsPopover), findsOneWidget);
      expect(find.byKey(kDocsPopoverSearch), findsOneWidget);
    });

    testWidgets(
      'a query with no matches says so instead of showing an empty panel',
      (tester) async {
        await _pump(tester, [_doc('docs/s.md', title: 'Spec S')]);
        await tester.tap(find.byType(DocsGlyphAnchorTapTarget));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(kDocsPopoverSearch), 'zzz');
        await tester.pumpAndSettle();
        expect(find.byType(DocRow), findsNothing);
        expect(find.textContaining('No docs match'), findsOneWidget);
      },
    );
  });
}
