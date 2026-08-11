// The per-repo Settings section: what each DTO state renders, and that the
// controls are wired rather than decorative.
//
// Interaction is asserted HERE rather than on the real app on purpose. Driving the
// built macOS app with cua-driver's synthesized clicks did not work — both a
// sidebar row and a 107x28pt segmented-button segment reported
// `"effect":"unverifiable"` and left the UI unchanged — so the real-app pass covers
// appearance only and these tests cover behaviour. That split is a stated coverage
// gap, not an accident.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/desktop/settings/sections/repository_section.dart';
import 'package:makit/ui/home/repo_monogram.dart';
import 'package:makit/ui/widgets/forge_glyph.dart';

const _base = RepoSettingsView(
  name: 'Diana',
  path: '/Users/le/Work/XDent/Diana',
  worktreeRoot: '/Users/le/.worktrees',
  defaultBranch: 'main',
  forge: ForgeKind.forgejo,
  forgeHost: 'forgejo.internal.xdent.ai',
  forgeAuthed: true,
  branches: ['main', 'develop'],
);

RepoSettingsView _view({
  ForgeKind? forge = ForgeKind.forgejo,
  String? forgeHost = 'forgejo.internal.xdent.ai',
  bool forgeAuthed = true,
  bool worktreeRootOverridden = false,
  bool editable = true,
  ForgeChoice providerChoice = ForgeChoice.auto,
  List<String> branches = const ['main', 'develop'],
  String? defaultBranch = 'main',
  bool hasRemote = true,
  int? logoHue,
}) => RepoSettingsView(
  name: _base.name,
  path: _base.path,
  worktreeRoot: _base.worktreeRoot,
  defaultBranch: defaultBranch,
  forge: forge,
  forgeHost: forgeHost,
  forgeAuthed: forgeAuthed,
  worktreeRootOverridden: worktreeRootOverridden,
  editable: editable,
  providerChoice: providerChoice,
  branches: branches,
  hasRemote: hasRemote,
  logoHue: logoHue,
);

Future<void> _pump(
  WidgetTester tester,
  RepoSettingsView view, {
  ValueChanged<ForgeChoice>? onChoose,
  VoidCallback? onReset,
  VoidCallback? onBranch,
  VoidCallback? onLogo,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: makitDarkTheme,
      home: Scaffold(
        body: RepositorySettingsSection(
          view: view,
          onChooseProvider: onChoose,
          onResetWorktreeRoot: onReset,
          onChooseDefaultBranch: onBranch,
          onEditLogo: onLogo,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('what it renders', () {
    testWidgets('the repo name is the page title, above the group headers', (t) async {
      await _pump(t, _view());
      expect(find.text('DIANA'), findsOneWidget);
      expect(find.text('IDENTITY'), findsOneWidget);
      expect(find.text('WORKTREES'), findsOneWidget);
    });

    testWidgets('paths are home-abbreviated, so the column is not spent on /Users/le', (t) async {
      await _pump(t, _view());
      expect(find.text('~/Work/XDent/Diana'), findsOneWidget);
      expect(find.text('/Users/le/Work/XDent/Diana'), findsNothing);
    });

    testWidgets('an unprobed repo omits the provider name but still offers the choice', (t) async {
      // `forge == null` means "not measured yet", never "no forge" — routing only
      // happens when a PR operation runs, so a quiet repo genuinely may not know.
      await _pump(t, _view(forge: null, forgeHost: null));
      expect(find.text('Auto: not identified yet'), findsOneWidget);
      expect(find.text('Forgejo'), findsOneWidget, reason: 'the segment, not a value');
      expect(find.byType(SegmentedButton<ForgeChoice>), findsOneWidget);
    });

    testWidgets('Auto names what it resolved to, so the default is not mysterious', (t) async {
      await _pump(t, _view());
      expect(
        find.text('Auto: Forgejo · forgejo.internal.xdent.ai · token set'),
        findsOneWidget,
      );
    });

    testWidgets('an unauthenticated instance says so rather than implying a token', (t) async {
      await _pump(t, _view(forgeAuthed: false));
      expect(find.textContaining('no token'), findsOneWidget);
    });

    testWidgets('provenance badges are absent — the row already says it', (t) async {
      // Pinned as a negative: `from name` beside a monogram, `from remote` beside
      // `main`, and `detected` beside a subtitle reading "Auto: Forgejo …" are all
      // the same sentence twice. Only resolution state earns a badge.
      await _pump(t, _view());
      expect(find.text('from name'), findsNothing);
      expect(find.text('from remote'), findsNothing);
      expect(find.text('detected'), findsNothing);
      expect(find.byTooltip('Copy path'), findsNothing);
      // …and the one badge that carries state is still there.
      expect(find.text('inherited'), findsOneWidget);
    });
  });

  group('no forge at all', () {
    testWidgets('None is offered beside the three forges', (t) async {
      await _pump(t, _view());
      expect(find.text('None'), findsOneWidget);
    });

    testWidgets('choosing None reports it', (t) async {
      final chosen = <ForgeChoice>[];
      await _pump(t, _view(), onChoose: chosen.add);
      await t.tap(find.text('None'));
      await t.pumpAndSettle();
      expect(chosen, [ForgeChoice.none]);
    });

    testWidgets('None says what it means for polling, not just that it is set', (t) async {
      await _pump(t, _view(providerChoice: ForgeChoice.none));
      expect(
        find.text('No forge · pull requests are not checked for this repository'),
        findsOneWidget,
      );
    });

    testWidgets('a repo with no remote is a conclusion, not a pending probe', (t) async {
      // These two states must NOT read the same: one has an answer, the other is
      // waiting for one, and only the second is worth looking into.
      await _pump(t, _view(forge: null, forgeHost: null, hasRemote: false));
      expect(find.text('Auto: no remote, so no forge'), findsOneWidget);
      expect(find.text('Auto: not identified yet'), findsNothing);
    });

    testWidgets('an unprobed repo WITH a remote still says a probe is pending', (t) async {
      await _pump(t, _view(forge: null, forgeHost: null));
      expect(find.text('Auto: not identified yet'), findsOneWidget);
    });

    testWidgets('None is an override, so it offers a way back to Auto', (t) async {
      final chosen = <ForgeChoice>[];
      await _pump(t, _view(providerChoice: ForgeChoice.none), onChoose: chosen.add);
      await t.tap(find.byTooltip('Reset to default').first);
      await t.pumpAndSettle();
      expect(chosen, [ForgeChoice.auto]);
    });
  });

  group('inheritance', () {
    testWidgets('inherited shows no reset button', (t) async {
      await _pump(t, _view());
      expect(find.text('inherited'), findsOneWidget);
      expect(find.byTooltip('Reset to default'), findsNothing);
    });

    testWidgets('overridden shows the badge AND the reset button', (t) async {
      await _pump(t, _view(worktreeRootOverridden: true));
      expect(find.text('overridden'), findsOneWidget);
      expect(find.byTooltip('Reset to default'), findsOneWidget);
    });

    testWidgets('only the row with no subtitle badges its override', (t) async {
      await _pump(
        t,
        _view(worktreeRootOverridden: true, providerChoice: ForgeChoice.gitea),
      );
      // Two things are overridden, but only Worktree root wears the chip; the
      // provider says it in prose. Two resets, one badge.
      expect(find.text('overridden'), findsOneWidget);
      expect(find.byTooltip('Reset to default'), findsNWidgets(2));
    });

    testWidgets('reset calls back — it does not silently do nothing', (t) async {
      var reset = 0;
      await _pump(t, _view(worktreeRootOverridden: true), onReset: () => reset++);
      await t.tap(find.byTooltip('Reset to default').first);
      await t.pumpAndSettle();
      expect(reset, 1);
    });
  });

  group('the provider selector is wired', () {
    testWidgets('choosing a forge reports that choice', (t) async {
      final chosen = <ForgeChoice>[];
      await _pump(t, _view(), onChoose: chosen.add);
      await t.tap(find.text('Gitea'));
      await t.pumpAndSettle();
      expect(chosen, [ForgeChoice.gitea]);
    });

    testWidgets('an override relabels the row and offers a way back to Auto', (t) async {
      await _pump(t, _view(providerChoice: ForgeChoice.gitea));
      expect(find.textContaining('Set to Gitea'), findsOneWidget);
      // No badge: the subtitle already says it. The reset button is the only
      // trailing element, because it is an action rather than a restatement — and
      // it returns to Auto rather than freezing today's detected value.
      expect(find.byTooltip('Reset to default'), findsOneWidget);
    });

    testWidgets('resetting the provider asks for Auto, not for the detected forge', (t) async {
      final chosen = <ForgeChoice>[];
      await _pump(t, _view(providerChoice: ForgeChoice.gitea), onChoose: chosen.add);
      await t.tap(find.byTooltip('Reset to default').first);
      await t.pumpAndSettle();
      expect(chosen, [ForgeChoice.auto]);
    });
  });

  group('read-only clients (D16: only loopback may write)', () {
    testWidgets('a non-editable view offers no selector and no reset', (t) async {
      final chosen = <ForgeChoice>[];
      await _pump(
        t,
        _view(editable: false, worktreeRootOverridden: true, providerChoice: ForgeChoice.gitea),
        onChoose: chosen.add,
      );
      expect(find.byTooltip('Reset to default'), findsNothing);
      // The control is present but inert: tapping must not report a choice.
      await t.tap(find.text('Forgejo'));
      await t.pumpAndSettle();
      expect(chosen, isEmpty);
      expect(
        find.textContaining('editable on the machine running makit'),
        findsOneWidget,
      );
    });
  });

  group('the chosen logo is actually drawn (SPEC-48 D14\u2032)', () {
    // The reason the row exists: two repos whose names hash to the same hue are
    // indistinguishable, which defeats the one job the monogram has. A choice that
    // does not change the mark leaves that defeat in place AND adds a control that
    // lies about having fixed it.
    testWidgets('a chosen hue overrides the name-derived one', (t) async {
      // The index is DERIVED, not hardcoded: 'Diana' happens to hash to 3, so a
      // hardcoded 3 asserted nothing. Picking the first index that differs keeps the
      // test honest if either the palette or the hash changes.
      final derived = RepoMonogram.hueFor(_base.name);
      final chosen = List.generate(RepoMonogram.paletteLength, (i) => i)
          .firstWhere((i) => RepoMonogram.paletteAt(i) != derived);
      await _pump(t, _view(logoHue: chosen));
      final mark = t.widget<RepoMonogram>(find.byType(RepoMonogram));
      expect(mark.hue, chosen);
      expect(RepoMonogram.paletteAt(mark.hue!), isNot(derived));
    });

    testWidgets('with no choice the mark stays name-derived', (t) async {
      await _pump(t, _view());
      expect(t.widget<RepoMonogram>(find.byType(RepoMonogram)).hue, isNull);
    });
  });

  group('editability of the identity rows', () {
    testWidgets('the logo row is tappable', (t) async {
      var taps = 0;
      await _pump(t, _view(), onLogo: () => taps++);
      await t.tap(find.text('Logo'));
      await t.pumpAndSettle();
      expect(taps, 1);
    });

    testWidgets('default branch is pickable when there are branches to pick', (t) async {
      var taps = 0;
      await _pump(t, _view(), onBranch: () => taps++);
      await t.tap(find.text('Default branch'));
      await t.pumpAndSettle();
      expect(taps, 1);
    });

    testWidgets('with no branches known the row does not open an empty picker', (t) async {
      var taps = 0;
      await _pump(t, _view(branches: const []), onBranch: () => taps++);
      await t.tap(find.text('Default branch'));
      await t.pumpAndSettle();
      expect(taps, 0);
    });
  });
}
