import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/docs.dart';
import 'package:makit/ui/docs/doc_preview.dart';

DocInfo _doc({DocKind kind = DocKind.md, String relPath = 'docs/x.md'}) =>
    DocInfo(
      key: '/repo:$relPath',
      relPath: relPath,
      title: 'SPEC-44 — Ports P4',
      kind: kind,
      bytes: 10,
      modifiedAt: 0,
      worktreePath: '/repo',
    );

const _md = '''
# SPEC-44 — Ports P4

**Status:** Draft (P1) · **Priority:** P3 · **Branch:** `feat/open-ports`

## D1 · Transport

Proxy over the existing HTTPS listener.
''';

/// A doc whose H1 differs from [DocInfo.title], so the body heading can be
/// found without also matching the toolbar's copy of the title.
const _mdOrdered = '''
# SPEC-44 — Ports P4: forward a loopback port

**Status:** Draft (P1) · **Priority:** P3 · **Branch:** `feat/open-ports`

Proxy over the existing HTTPS listener.
''';

Future<void> _pump(
  WidgetTester tester,
  DocInfo doc, {
  String? markdown,
  VoidCallback? onPublish,
  void Function(String)? onOpenInternal,
  void Function(Uri)? onExternalLink,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: DocPreview(
        doc: doc,
        markdown: markdown,
        onPublish: onPublish,
        onOpenInternal: onOpenInternal,
        onExternalLink: onExternalLink,
      ),
    ),
  ),
);

void main() {
  group('resolveDocLink', () {
    test('http/https links are external', () {
      expect(resolveDocLink('https://x.com/a').kind, DocLinkKind.external);
      expect(resolveDocLink('http://x.com').kind, DocLinkKind.external);
    });

    test('a relative .md / .html path is an internal doc link', () {
      final t = resolveDocLink('../specs/SPEC-41.md');
      expect(t.kind, DocLinkKind.internal);
      expect(t.value, '../specs/SPEC-41.md');
      expect(resolveDocLink('mockups/x.html').kind, DocLinkKind.internal);
    });

    test('a non-doc relative link is external (fallback, not swallowed)', () {
      expect(resolveDocLink('https://a').kind, DocLinkKind.external);
      expect(resolveDocLink('mailto:x@y.com').kind, DocLinkKind.external);
    });
  });

  group('DocPreview — markdown', () {
    testWidgets('renders the markdown body', (tester) async {
      await _pump(tester, _doc(), markdown: _md);
      // Two bodies when a front-matter line splits the doc: the lead (the H1)
      // above the chip strip, and the remainder below it.
      expect(find.byType(MarkdownBody), findsNWidgets(2));
      expect(find.textContaining('Proxy over the existing'), findsOneWidget);
    });

    testWidgets('strips the front-matter line and renders it as chips', (
      tester,
    ) async {
      await _pump(tester, _doc(), markdown: _md);
      // The chips are present…
      expect(find.byKey(kDocFrontMatter), findsOneWidget);
      expect(find.textContaining('Draft'), findsWidgets);
      expect(find.textContaining('P3'), findsWidgets);
      expect(find.textContaining('feat/open-ports'), findsWidgets);
      // …and the raw markdown front-matter line is gone from the body.
      expect(find.textContaining('**Status:**'), findsNothing);
    });

    // The source file puts the H1 on line 1 and the `**Status:**` line under it,
    // and mockup Card 6 draws title-then-status. Hoisting the chips above the
    // title inverts the hierarchy of every spec in the repo, and the toolbar
    // already carries the title, so the strip must not outrank the heading.
    testWidgets('the front-matter strip renders below the H1, never above it', (
      tester,
    ) async {
      await _pump(tester, _doc(), markdown: _mdOrdered);
      final h1 = tester.getTopLeft(
        find.textContaining('forward a loopback port'),
      );
      final chips = tester.getTopLeft(find.byKey(kDocFrontMatter));
      expect(
        chips.dy,
        greaterThan(h1.dy),
        reason: 'the document title must lead; the metadata strip follows it',
      );
    });

    testWidgets('a doc with no front-matter line renders unchanged', (
      tester,
    ) async {
      await _pump(tester, _doc(), markdown: '# Plain\n\nNo status line here.');
      expect(find.byKey(kDocFrontMatter), findsNothing);
      expect(find.textContaining('No status line here.'), findsOneWidget);
    });

    testWidgets('shows a spinner while markdown is loading', (tester) async {
      await _pump(tester, _doc(), markdown: null);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('reader-width toggle is present and toggles', (tester) async {
      await _pump(tester, _doc(), markdown: _md);
      final toggle = find.byKey(kDocReaderWidthToggle);
      expect(toggle, findsOneWidget);
      await tester.tap(toggle);
      await tester.pump();
      // Still present after toggling (state flips, widget stays).
      expect(toggle, findsOneWidget);
    });
  });

  // D8 rev 2: the same sheet, two primary actions, decided by whether the client
  // shares a machine with the server. Publishing works everywhere, so it stays
  // reachable locally as the secondary — but it must not be the only way, which
  // is what made a board unopenable with Tailscale off.
  group('DocPreview — html actions (D8 rev 2)', () {
    testWidgets('a remote client gets Publish & open as the only action', (
      tester,
    ) async {
      await _pump(tester, _doc(kind: DocKind.html), onPublish: () {});
      expect(find.byKey(kDocPublishButton), findsOneWidget);
      expect(find.byKey(kDocOpenLocalButton), findsNothing);
      expect(find.text('Publish & open'), findsOneWidget);
      expect(find.textContaining('Publish it to your tailnet'), findsOneWidget);
    });

    testWidgets('a local client leads with Open in browser, publish demoted', (
      tester,
    ) async {
      var opened = 0;
      var published = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DocPreview(
              doc: _doc(kind: DocKind.html),
              onPublish: () => published++,
              onOpenLocal: () => opened++,
            ),
          ),
        ),
      );
      expect(find.byKey(kDocOpenLocalButton), findsOneWidget);
      expect(find.text('Open in browser'), findsOneWidget);
      // The copy must stop telling a local user to publish.
      expect(find.textContaining('Publish it to your tailnet'), findsNothing);
      expect(
        find.textContaining('on this machine'),
        findsOneWidget,
        reason: 'say why no server is needed',
      );
      // Publish is still reachable — that is how a board reaches the phone.
      expect(find.text('Share to a device…'), findsOneWidget);

      await tester.tap(find.byKey(kDocOpenLocalButton));
      expect(opened, equals(1));
      expect(
        published,
        equals(0),
      );
    });
  });

  group('DocPreview — html (D8: no in-app render in P1)', () {
    testWidgets(
      'html shows no markdown; Publish & open is the primary action',
      (tester) async {
        var published = false;
        await _pump(
          tester,
          _doc(kind: DocKind.html, relPath: 'mockups/x.html'),
          onPublish: () => published = true,
        );
        expect(find.byType(MarkdownBody), findsNothing);
        expect(find.text('Publish & open'), findsOneWidget);
        await tester.tap(find.text('Publish & open'));
        expect(published, isTrue);
      },
    );
  });
}
