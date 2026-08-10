import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/docs.dart';
import 'package:makit/ui/docs/doc_row.dart';
import 'package:makit/ui/docs/doc_vocabulary.dart';

DocInfo _doc({
  String relPath = 'mockups/a.html',
  String title = 'Board A',
  DocKind kind = DocKind.html,
  int bytes = 42000,
  int modifiedAt = 0,
  bool? changed,
  String? docStatus,
}) => DocInfo(
  key: '/repo:$relPath',
  relPath: relPath,
  title: title,
  kind: kind,
  bytes: bytes,
  modifiedAt: modifiedAt,
  worktreePath: '/repo',
  changed: changed,
  docStatus: docStatus,
);

Future<void> _pump(WidgetTester tester, DocInfo doc, {int nowMs = 0}) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DocRow(doc: doc, nowMs: nowMs, onTap: () {}),
        ),
      ),
    );

void main() {
  group('doc vocabulary', () {
    test('size label uses KB / MB, never bytes', () {
      expect(docSizeLabel(42000), '41 KB');
      expect(docSizeLabel(900), '900 B');
      expect(docSizeLabel(5 * 1024 * 1024), '5.0 MB');
    });

    test('relative mtime: minutes, hours, yesterday, days', () {
      const min = 60 * 1000;
      const hour = 60 * min;
      const day = 24 * hour;
      expect(docRelativeTime(0, nowMs: 2 * min), '2 min ago');
      expect(docRelativeTime(0, nowMs: 3 * hour), '3 h ago');
      expect(docRelativeTime(0, nowMs: 30 * hour), 'yesterday');
      expect(docRelativeTime(0, nowMs: 3 * day), '3 days ago');
    });

    test('kind colour is warm for html, cool for md', () {
      expect(docKindColor(DocKind.html), kDocHtmlColor);
      expect(docKindColor(DocKind.md), kDocMdColor);
    });
  });

  group('DocRow', () {
    testWidgets('shows the extracted title, never the filename', (
      tester,
    ) async {
      await _pump(
        tester,
        _doc(title: 'SPEC-46 — Docs preview', relPath: 'docs/x.md'),
      );
      expect(find.text('SPEC-46 — Docs preview'), findsOneWidget);
      // The bare filename is never shown as the title.
      expect(find.text('x.md'), findsNothing);
    });

    // The full path, not just the relPath: for a root-level file the relPath is
    // identical to the title (`Notes` / `NOTES.md`) and says nothing about where
    // the file lives. Truncation is from the LEFT so the filename survives,
    // which is why the string is wrapped in an LTR isolate (U+2066/U+2069) —
    // without it the leading `/` reorders to the wrong end in the RTL paragraph.
    testWidgets('shows the full path, LTR-isolated for left truncation', (
      tester,
    ) async {
      await _pump(tester, _doc(relPath: 'mockups/open-ports.html'));
      expect(
        find.text('\u2066/repo/mockups/open-ports.html\u2069'),
        findsOneWidget,
      );

      final dir = tester.widget<Directionality>(
        find.ancestor(
          of: find.text('\u2066/repo/mockups/open-ports.html\u2069'),
          matching: find.byType(Directionality),
        ).first,
      );
      expect(
        dir.textDirection,
        TextDirection.rtl,
        reason: 'an RTL paragraph puts the ellipsis at the visual start',
      );
    });

    testWidgets('docFullPath joins worktree and relPath without a double slash', (
      tester,
    ) async {
      expect(
        docFullPath(_doc(relPath: 'a/b.md')),
        '/repo/a/b.md',
      );
      expect(
        docFullPath(
          const DocInfo(
            key: 'k',
            relPath: 'NOTES.md',
            title: 'Notes',
            kind: DocKind.md,
            bytes: 1,
            modifiedAt: 0,
            worktreePath: '/repo/',
          ),
        ),
        '/repo/NOTES.md',
        reason: 'a trailing slash on the worktree must not double up',
      );
    });

    testWidgets('renders the kind chip (HTML / MD)', (tester) async {
      await _pump(tester, _doc(kind: DocKind.html));
      expect(find.text('HTML'), findsOneWidget);
      await _pump(tester, _doc(kind: DocKind.md));
      expect(find.text('MD'), findsOneWidget);
    });

    testWidgets('changed doc shows a changed chip; unchanged shows none', (
      tester,
    ) async {
      await _pump(tester, _doc(changed: true));
      expect(find.byKey(kDocChangedChip), findsOneWidget);
      await _pump(tester, _doc(changed: null));
      expect(find.byKey(kDocChangedChip), findsNothing);
      await _pump(tester, _doc(changed: false));
      expect(find.byKey(kDocChangedChip), findsNothing);
    });

    testWidgets('a draft status badge is shown; absent status shows none', (
      tester,
    ) async {
      await _pump(tester, _doc(docStatus: 'Draft'));
      expect(find.text('draft'), findsOneWidget);
      await _pump(tester, _doc(docStatus: null));
      expect(find.byKey(kDocStatusBadge), findsNothing);
    });

    testWidgets('shows size and relative mtime', (tester) async {
      const twoMin = 2 * 60 * 1000;
      await _pump(tester, _doc(bytes: 42000, modifiedAt: 0), nowMs: twoMin);
      expect(find.textContaining('41 KB'), findsOneWidget);
      expect(find.textContaining('2 min ago'), findsOneWidget);
    });

    testWidgets('tapping the row fires onTap', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DocRow(doc: _doc(), nowMs: 0, onTap: () => tapped = true),
          ),
        ),
      );
      await tester.tap(find.byType(DocRow));
      expect(tapped, isTrue);
    });
  });
}
