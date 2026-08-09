import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/ui/docs/doc_glyph.dart';

Future<void> _pump(WidgetTester tester, int count) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Center(child: DocsGlyph(count: count)),
    ),
  ),
);

void main() {
  testWidgets('renders nothing when the worktree has no docs', (tester) async {
    await _pump(tester, 0);
    expect(find.byType(Icon), findsNothing);
  });

  testWidgets('renders the file glyph with a spoken count label', (
    tester,
  ) async {
    await _pump(tester, 3);
    expect(find.byType(Icon), findsOneWidget);
    expect(find.bySemanticsLabel('3 docs'), findsOneWidget);
  });

  testWidgets('singular label for one doc', (tester) async {
    await _pump(tester, 1);
    expect(find.bySemanticsLabel('1 doc'), findsOneWidget);
  });
}
