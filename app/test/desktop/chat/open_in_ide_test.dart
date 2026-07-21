// Tests for the title-bar "Open in…" IDE launcher command mapping.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/open_in_ide.dart';

void main() {
  group('ideOpenCommand', () {
    test('reveals the folder in Finder with a bare open', () {
      final cmd = ideOpenCommand(IdeTarget.finder, '/repo/wt');
      expect(cmd.executable, 'open');
      expect(cmd.args, ['/repo/wt']);
    });

    test('launches editors by application name via open -a', () {
      expect(ideOpenCommand(IdeTarget.vscode, '/repo/wt').args, [
        '-a',
        'Visual Studio Code',
        '/repo/wt',
      ]);
      expect(ideOpenCommand(IdeTarget.cursor, '/repo/wt').args, [
        '-a',
        'Cursor',
        '/repo/wt',
      ]);
      expect(ideOpenCommand(IdeTarget.zed, '/repo/wt').args, [
        '-a',
        'Zed',
        '/repo/wt',
      ]);
    });

    test('launches terminals by their macOS app name', () {
      expect(ideOpenCommand(IdeTarget.ghostty, '/repo/wt').args, [
        '-a',
        'Ghostty',
        '/repo/wt',
      ]);
      // iTerm2's bundle is "iTerm", not its marketing name.
      expect(ideOpenCommand(IdeTarget.iterm, '/repo/wt').args, [
        '-a',
        'iTerm',
        '/repo/wt',
      ]);
      expect(ideOpenCommand(IdeTarget.terminal, '/repo/wt').args, [
        '-a',
        'Terminal',
        '/repo/wt',
      ]);
    });
  });

  group('ideTargetFromName', () {
    test('resolves each stored name back to its target', () {
      for (final target in IdeTarget.values) {
        expect(ideTargetFromName(target.name), target);
      }
    });

    test('falls back to VS Code for an unknown/legacy value', () {
      expect(ideTargetFromName('emacs'), IdeTarget.vscode);
      expect(ideTargetFromName(''), IdeTarget.vscode);
    });
  });

  group('ideLogo', () {
    Future<void> pumpLogo(
      WidgetTester tester,
      IdeTarget target, {
      required Brightness brightness,
    }) => tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: Scaffold(
          body: Builder(builder: (context) => ideLogo(context, target)),
        ),
      ),
    );

    testWidgets('renders official brand SVGs for editors', (tester) async {
      for (final target in [
        IdeTarget.vscode,
        IdeTarget.zed,
        IdeTarget.ghostty,
        IdeTarget.cursor,
        IdeTarget.iterm,
      ]) {
        await pumpLogo(tester, target, brightness: Brightness.light);
        expect(
          find.byType(SvgPicture),
          findsOneWidget,
          reason: '${target.name} should render an SVG logo',
        );
      }
    });

    testWidgets('uses a neutral glyph (not a fake logo) for Apple apps', (
      tester,
    ) async {
      for (final target in [IdeTarget.terminal, IdeTarget.finder]) {
        await pumpLogo(tester, target, brightness: Brightness.light);
        expect(find.byType(Icon), findsOneWidget);
        expect(find.byType(SvgPicture), findsNothing);
      }
    });

    testWidgets('picks the -light variant on a dark background', (
      tester,
    ) async {
      await pumpLogo(tester, IdeTarget.vscode, brightness: Brightness.dark);
      final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
      final loader = svg.bytesLoader as SvgAssetLoader;
      expect(loader.assetName, 'assets/ide/visual-studio-code-light.svg');
    });

    testWidgets('picks the colored variant on a light background', (
      tester,
    ) async {
      await pumpLogo(tester, IdeTarget.vscode, brightness: Brightness.light);
      final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
      final loader = svg.bytesLoader as SvgAssetLoader;
      expect(loader.assetName, 'assets/ide/visual-studio-code.svg');
    });
  });

  group('OpenInIdeButton (M3 split button)', () {
    Future<void> pump(WidgetTester tester) => tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: OpenInIdeButton(path: '/repo/wt')),
        ),
      ),
    );

    testWidgets('renders two tonal segments with M3 ink state layers', (
      tester,
    ) async {
      await pump(tester);
      // Caret segment + logo (action) segment, each an InkWell over Material.
      expect(find.byType(InkWell), findsNWidgets(2));
    });

    testWidgets('caret opens a menu listing every editor', (tester) async {
      await pump(tester);
      // Tap the leading caret segment (first InkWell) to open the menu; the
      // trailing segment is the primary action (opens the editor directly).
      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();
      // Every target is offered, with VS Code (the default) shown too.
      expect(find.text('Open in VS Code'), findsWidgets);
      expect(find.text('Open in Ghostty'), findsOneWidget);
      expect(find.text('Open in iTerm2'), findsOneWidget);
      expect(find.text('Reveal in Finder'), findsOneWidget);
    });
  });
}
