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
      // Tap the trailing caret segment (last InkWell) to open the menu; the
      // leading segment is the primary action (opens the editor directly).
      await tester.tap(find.byType(InkWell).last);
      await tester.pumpAndSettle();
      // Every target is offered, with VS Code (the default) shown too.
      expect(find.text('VS Code'), findsWidgets);
      expect(find.text('Ghostty'), findsOneWidget);
      expect(find.text('iTerm2'), findsOneWidget);
      expect(find.text('Finder'), findsOneWidget);
    });

    testWidgets('a null path disables the launcher (nothing to open)', (
      tester,
    ) async {
      // SPEC-30 decision 11: a board with no focused pane owns no scope, so the
      // launcher is disabled rather than lying about a target.
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: Scaffold(body: OpenInIdeButton(path: null))),
        ),
      );
      await tester.pumpAndSettle();

      // Both segments are inert, not just the menu.
      final button = tester.widget<OpenInIdeButton>(
        find.byType(OpenInIdeButton),
      );
      expect(button.path, isNull);
      await tester.tap(find.byType(InkWell).last);
      await tester.pumpAndSettle();
      expect(find.text('VS Code'), findsNothing);
      expect(find.text('Finder'), findsNothing);
      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();
      expect(find.text('VS Code'), findsNothing);

      // It is visibly disabled, and it does not narrate an action it will not
      // take (a dead control describing "VS Code" is worse than none).
      // Dimmed *and* inert: without IgnorePointer the disabled control still
      // takes hover cursors and is reachable by assistive technology, i.e. it
      // advertises an action it will not perform.
      expect(
        find
                .ancestor(
                  of: find.byType(OpenInIdeButton),
                  matching: find.byType(IgnorePointer),
                )
                .evaluate()
                .isNotEmpty ||
            find
                .descendant(
                  of: find.byType(OpenInIdeButton),
                  matching: find.byType(IgnorePointer),
                )
                .evaluate()
                .isNotEmpty,
        isTrue,
        reason: 'the disabled launcher must not take pointer events',
      );
      final dim = tester.widgetList<Opacity>(
        find.descendant(
          of: find.byType(OpenInIdeButton),
          matching: find.byType(Opacity),
        ),
      );
      expect(dim.map((o) => o.opacity), contains(0.4));
      expect(
        find.byTooltip('Nothing to open — this board has no panes'),
        findsOneWidget,
      );
      expect(find.byTooltip('VS Code'), findsNothing);
    });

    testWidgets('the menu names the folder it will open (decision 11)', (
      tester,
    ) async {
      // The button is icon-only *because* the menu discloses the target; the
      // title strip no longer carries a branch label (decision 10), so without
      // this header nothing on screen says which worktree opens.
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: OpenInIdeButton(path: '/tmp/wt/feat-login')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Choose editor'));
      await tester.pumpAndSettle();

      expect(find.text('Opens the active pane'), findsOneWidget);
      // The worktree name is disclosed in full (short path, no head-truncation).
      expect(find.text('/tmp/wt/feat-login'), findsOneWidget);
      expect(find.text('Cursor'), findsOneWidget);
    });

    testWidgets('a deep path head-truncates so the worktree name survives', (
      tester,
    ) async {
      // Long leading path, short identifying tail: the head must collapse to
      // '…' while the worktree folder name is kept.
      const deep =
          '/Users/dev/projects/monorepo/checkouts/worktrees/nested/zubby';
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: OpenInIdeButton(path: deep)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Choose editor'));
      await tester.pumpAndSettle();

      // The full path doesn't fit, so the head collapsed to '…' — but the
      // identifying tail (the worktree folder name) is still shown.
      final header = tester.widget<Text>(find.textContaining('zubby'));
      expect(header.data, startsWith('…'));
      expect(header.data, endsWith('zubby'));
    });
  });
}
