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
}
