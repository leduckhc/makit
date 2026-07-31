import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/desktop/chat/github_budget_button.dart';
import 'package:makit/desktop/chat/sidebar_layout.dart';
import 'package:makit/desktop/settings/prefs/preferences_controller.dart';
import 'package:makit/desktop/settings/prefs/preferences_providers.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

BudgetBucket _bucket({
  int limit = 5000,
  int remaining = 1769,
  int mine = 2100,
  int others = 1131,
  int resetAt = 0,
}) => BudgetBucket(
  limit: limit,
  remaining: remaining,
  resetAt: resetAt,
  mine: mine,
  others: others,
);

GithubBudget _budget({
  BudgetBucket? core = const BudgetBucket(
    limit: 5000,
    remaining: 1769,
    resetAt: 0,
    mine: 2100,
    others: 1131,
  ),
  BudgetBucket? graphql = const BudgetBucket(
    limit: 5000,
    remaining: 4188,
    resetAt: 0,
    mine: 400,
    others: 200,
  ),
  BudgetBucket? search,
  int burnPerHour = 340,
  int? msUntilEmpty = 18 * 60 * 1000,
  BudgetLevel level = BudgetLevel.warm,
  List<String> throttles = const ['unresolved', 'poll30'],
  int? retryAfterMs,
  List<BudgetHistorySlot> history = const [],
}) => GithubBudget(
  core: core,
  graphql: graphql,
  search: search,
  burnPerHour: burnPerHour,
  msUntilEmpty: msUntilEmpty,
  level: level,
  throttles: throttles,
  retryAfterMs: retryAfterMs,
  measuredAt: 0,
  history: history,
  stats: null,
);

Widget _host({
  GithubBudget? budget,
  PreferencesController? controller,
  Key? buttonKey,
  void Function(String kind)? onCmd,
}) {
  return ProviderScope(
    overrides: [
      githubBudgetProvider.overrideWithValue(budget),
      preferencesControllerProvider.overrideWith(
        (ref) => controller ?? PreferencesController.ephemeral(),
      ),
      if (onCmd != null)
        storeControllerProvider.overrideWith(
          (ref) => _SpyStoreController(ref, onCmd),
        ),
    ],
    child: MaterialApp(
      home: Scaffold(
        // Bottom-anchored, like the real footer, so the popover opens upward.
        body: Align(
          alignment: Alignment.bottomRight,
          child: GithubBudgetButton(key: buttonKey),
        ),
      ),
    ),
  );
}

Future<void> _openPopover(WidgetTester tester) async {
  await tester.tap(find.byIcon(PhosphorIconsLight.githubLogo));
  await tester.pumpAndSettle();
}

void main() {
  group('icon colour per level', () {
    const cs = ColorScheme.dark();
    test('healthy is the plain outline (no coloured status light)', () {
      expect(githubBudgetIconColor(BudgetLevel.healthy, cs), cs.outline);
    });
    test('warm is the warning token', () {
      expect(githubBudgetIconColor(BudgetLevel.warm, cs), kStatusWarning);
    });
    test('critical is the delete/error token', () {
      expect(githubBudgetIconColor(BudgetLevel.critical, cs), kDiffDel);
    });
    test('paused is the delete/error token', () {
      expect(githubBudgetIconColor(BudgetLevel.paused, cs), kDiffDel);
    });
    test('unknown is a dimmed outline', () {
      expect(
        githubBudgetIconColor(BudgetLevel.unknown, cs),
        cs.outline.withValues(alpha: 0.4),
      );
    });
  });

  testWidgets('renders the GitHub glyph in the footer', (tester) async {
    await tester.pumpWidget(_host(budget: _budget()));
    expect(find.byIcon(PhosphorIconsLight.githubLogo), findsOneWidget);
  });

  testWidgets('hover tooltip carries the one-line warm summary', (
    tester,
  ) async {
    await tester.pumpWidget(_host(budget: _budget()));
    expect(
      find.byTooltip(
        'quota runs out in 18 min · 1,769 REST left · click for detail',
      ),
      findsOneWidget,
    );
  });

  testWidgets('healthy tooltip names the budget and REST left', (tester) async {
    await tester.pumpWidget(
      _host(
        budget: _budget(
          level: BudgetLevel.healthy,
          msUntilEmpty: null,
          core: _bucket(remaining: 4812),
          throttles: const [],
        ),
      ),
    );
    expect(
      find.byTooltip('GitHub API budget — healthy · 4,812 REST left'),
      findsOneWidget,
    );
  });

  testWidgets('tap opens the popover; Esc dismisses it', (tester) async {
    await tester.pumpWidget(_host(budget: _budget()));
    expect(find.text('GitHub API budget'), findsNothing);

    await _openPopover(tester);
    expect(find.text('GitHub API budget'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('GitHub API budget'), findsNothing);
  });

  testWidgets('tap opens the popover; outside tap dismisses it', (
    tester,
  ) async {
    await tester.pumpWidget(_host(budget: _budget()));
    await _openPopover(tester);
    expect(find.text('GitHub API budget'), findsOneWidget);

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('GitHub API budget'), findsNothing);
  });

  testWidgets('renders bars only for measured buckets', (tester) async {
    // graphql unmeasured (null) must NOT render a zeroed bar.
    await tester.pumpWidget(_host(budget: _budget(graphql: null)));
    await _openPopover(tester);
    expect(find.byKey(kBudgetBarCoreKey), findsOneWidget);
    expect(find.byKey(kBudgetBarGraphqlKey), findsNothing);
  });

  testWidgets('search row hidden when idle, shown when non-idle', (
    tester,
  ) async {
    // Idle: remaining == limit → hidden.
    await tester.pumpWidget(
      _host(
        buttonKey: const ValueKey('idle'),
        budget: _budget(search: _bucket(limit: 30, remaining: 30, others: 0)),
      ),
    );
    await _openPopover(tester);
    expect(find.byKey(kBudgetSearchRowKey), findsNothing);

    // Non-idle: remaining < limit → shown.
    await tester.pumpWidget(
      _host(
        buttonKey: const ValueKey('nonidle'),
        budget: _budget(search: _bucket(limit: 30, remaining: 24, others: 6)),
      ),
    );
    await _openPopover(tester);
    expect(find.byKey(kBudgetSearchRowKey), findsOneWidget);
  });

  testWidgets('throttle badge hidden when throttles empty', (tester) async {
    await tester.pumpWidget(
      _host(
        buttonKey: const ValueKey('empty'),
        budget: _budget(throttles: const [], level: BudgetLevel.healthy),
      ),
    );
    await _openPopover(tester);
    expect(find.byKey(kBudgetThrottleBadgeKey), findsNothing);

    await tester.pumpWidget(
      _host(buttonKey: const ValueKey('some'), budget: _budget()),
    );
    await _openPopover(tester);
    expect(find.byKey(kBudgetThrottleBadgeKey), findsOneWidget);
  });

  testWidgets('tapping the pill reveals the sparkline and ladder', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        budget: _budget(
          history: const [
            BudgetHistorySlot(mine: 3, others: 1),
            BudgetHistorySlot(mine: 5, others: 2),
          ],
        ),
      ),
    );
    await _openPopover(tester);
    expect(find.byKey(kBudgetSparklineKey), findsNothing);
    expect(find.byKey(kBudgetLadderKey), findsNothing);

    await tester.tap(find.byKey(kBudgetHistoryPillKey));
    await tester.pumpAndSettle();
    expect(find.byKey(kBudgetSparklineKey), findsOneWidget);
    expect(find.byKey(kBudgetLadderKey), findsOneWidget);
  });

  testWidgets('a null budget renders without throwing', (tester) async {
    await tester.pumpWidget(_host(budget: null));
    expect(find.byIcon(PhosphorIconsLight.githubLogo), findsOneWidget);
    await _openPopover(tester);
    expect(find.textContaining('Not measured yet'), findsOneWidget);
  });

  testWidgets('an all-null-bucket unknown budget renders without throwing', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        budget: _budget(
          core: null,
          graphql: null,
          search: null,
          level: BudgetLevel.unknown,
          msUntilEmpty: null,
          throttles: const [],
        ),
      ),
    );
    await _openPopover(tester);
    expect(find.textContaining('Not measured yet'), findsOneWidget);
    expect(find.byKey(kBudgetBarCoreKey), findsNothing);
  });

  testWidgets('Refresh is live and asks the server to re-read the quota', (
    tester,
  ) async {
    // /rate_limit is quota-exempt, so this control must actually work rather
    // than be a decorative label -- an inert button is worse than none.
    final calls = <String>[];
    await tester.pumpWidget(_host(budget: _budget(), onCmd: calls.add));
    await _openPopover(tester);
    await tester.tap(find.byKey(kBudgetRefreshKey));
    await tester.pumpAndSettle();
    expect(calls, contains('github.refresh'));
  });

  testWidgets('Pause polling is live once the detail is expanded', (
    tester,
  ) async {
    final calls = <String>[];
    final controller = PreferencesController.ephemeral();
    await tester.pumpWidget(
      _host(budget: _budget(), controller: controller, onCmd: calls.add),
    );
    await _openPopover(tester);
    await tester.tap(find.byKey(kBudgetHistoryPillKey));
    await tester.pumpAndSettle();
    // The popover is height-capped and scrolls, so the button at the bottom of
    // the expanded detail may be below the fold -- scroll to it as a user would.
    await tester.ensureVisible(find.byKey(kBudgetPauseKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kBudgetPauseKey));
    await tester.pumpAndSettle();
    expect(calls, contains('github.pause'));
  });

  testWidgets('the invariant rung is never struck through', (tester) async {
    // "Your own actions are never blocked" is a GUARANTEE, not a shed step.
    // Striking it (which raw throttles.length did once the list reached 5) would
    // tell the user the exact opposite of the promise the reserve exists to keep.
    await tester.pumpWidget(
      _host(
        budget: _budget(
          level: BudgetLevel.paused,
          throttles: const ['a', 'b', 'c', 'd', 'e', 'f'],
        ),
        controller: PreferencesController.ephemeral(),
      ),
    );
    await _openPopover(tester);
    await tester.tap(find.byKey(kBudgetHistoryPillKey));
    await tester.pumpAndSettle();

    final invariant = tester.widget<Text>(
      find.text('Your own actions are never blocked'),
    );
    expect(invariant.style?.decoration, isNot(TextDecoration.lineThrough));
  });

  /// Hosts the button where the REAL footer puts it: at the bottom of a
  /// left-hand sidebar of [sidebarWidth], with the icon third from the right
  /// (Add repo / archive / gear sit to its right, 32px each).
  Widget hostInFooter({
    required GithubBudget? budget,
    double sidebarWidth = kSidebarDefaultWidth,
    PreferencesController? controller,
  }) {
    return ProviderScope(
      overrides: [
        githubBudgetProvider.overrideWithValue(budget),
        preferencesControllerProvider.overrideWith(
          (ref) => controller ?? PreferencesController.ephemeral(),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: sidebarWidth,
                child: const Column(
                  children: [
                    Spacer(),
                    Row(
                      children: [
                        Spacer(),
                        GithubBudgetButton(),
                        // Add repo / archive / gear sit to its right, 32px each.
                        SizedBox(width: 32),
                        SizedBox(width: 32),
                        SizedBox(width: 32),
                      ],
                    ),
                  ],
                ),
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('the popover stays on screen when opened from the footer', (
    tester,
  ) async {
    // The icon lives ~216px from the left inside a 320px sidebar, and the
    // popover is 300px wide -- so right-aligning it to the icon put its left
    // edge at about -84px, i.e. off the left of the window entirely.
    await tester.pumpWidget(hostInFooter(budget: _budget()));
    await _openPopover(tester);

    final screen =
        Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;
    final popover = tester.getRect(find.byKey(kBudgetPopoverKey));
    expect(popover.left, greaterThanOrEqualTo(0), reason: 'off the left edge');
    expect(
      popover.right,
      lessThanOrEqualTo(screen.right),
      reason: 'off the right edge',
    );
    expect(popover.top, greaterThanOrEqualTo(0), reason: 'off the top edge');
    expect(
      popover.bottom,
      lessThanOrEqualTo(screen.bottom),
      reason: 'off the bottom',
    );
  });

  testWidgets('the popover stays on screen at the minimum sidebar width', (
    tester,
  ) async {
    await tester.pumpWidget(
      hostInFooter(budget: _budget(), sidebarWidth: kSidebarMinWidth),
    );
    await _openPopover(tester);
    final popover = tester.getRect(find.byKey(kBudgetPopoverKey));
    expect(popover.left, greaterThanOrEqualTo(0));
  });

  testWidgets('an expanded popover fits a short window by scrolling', (
    tester,
  ) async {
    // Fully expanded the content is ~540px; in a short window it must scroll
    // inside the available space rather than run off the top of the screen.
    tester.view.physicalSize = const Size(1200, 420);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = PreferencesController.ephemeral();
    await tester.pumpWidget(
      hostInFooter(budget: _budget(), controller: controller),
    );
    await _openPopover(tester);
    // In a short window the popover scrolls, so the pill can start below the
    // fold; tapping its raw offset would hit the dismiss barrier instead.
    await tester.ensureVisible(find.byKey(kBudgetHistoryPillKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kBudgetHistoryPillKey));
    await tester.pumpAndSettle();

    final popover = tester.getRect(find.byKey(kBudgetPopoverKey));
    expect(popover.top, greaterThanOrEqualTo(0), reason: 'ran off the top');
    expect(
      find.byType(Scrollable),
      findsWidgets,
      reason: 'overflow must scroll',
    );
  });

  testWidgets('the Burn history label is never truncated', (tester) async {
    // The pill sat in a Flexible NEXT TO a Spacer, and Spacer is Expanded(flex:1)
    // -- so the row split its free space 1:1 and squeezed the pill until the
    // label ellipsised to "Burn hi...". A fixed two-word control label should
    // never ellipsis; the Spacer alone should absorb the slack.
    await tester.pumpWidget(_host(budget: _budget()));
    await _openPopover(tester);

    final label = tester.renderObject<RenderParagraph>(
      find.text('Burn history'),
    );
    // Asserting laid-out vs. intrinsic width catches truncation however it is
    // configured (ellipsis, fade, or a hard clip).
    expect(
      label.size.width,
      closeTo(label.getMaxIntrinsicWidth(double.infinity), 0.5),
      reason: 'the label was denied the width it asked for',
    );
    // NB: `flutter test` substitutes a fixed-width test font (~11.5px/char at
    // labelSmall vs ~5px for SF Pro Text), so this row is far more cramped here
    // than in the real app -- "Burn history" measures ~138px under test and
    // ~62px shipped. That makes this a deliberately harsh check: the row must
    // still lay out without a RenderFlex overflow, which it does by letting the
    // Refresh label (the element that may safely shrink) ellipsis instead.
    expect(tester.takeException(), isNull, reason: 'the row overflowed');
  });

  testWidgets('the Burn history label survives the throttle badge', (
    tester,
  ) async {
    // The badge and caret share the pill, so the label must still fit with them
    // present -- the widest configuration.
    await tester.pumpWidget(
      _host(budget: _budget(throttles: const ['a', 'b', 'c'])),
    );
    await _openPopover(tester);
    expect(find.byKey(kBudgetThrottleBadgeKey), findsOneWidget);
    final label = tester.renderObject<RenderParagraph>(
      find.text('Burn history'),
    );
    expect(
      label.size.width,
      closeTo(label.getMaxIntrinsicWidth(double.infinity), 0.5),
    );
  });

  testWidgets('an empty burn history says so instead of drawing a blank chart', (
    tester,
  ) async {
    // A fresh server has no minutes recorded, and all-zero slots paint as a flat
    // line on the floor -- indistinguishable from a broken chart.
    await tester.pumpWidget(
      _host(budget: _budget(), controller: PreferencesController.ephemeral()),
    );
    await _openPopover(tester);
    await tester.tap(find.byKey(kBudgetHistoryPillKey));
    await tester.pumpAndSettle();
    expect(find.text('No activity recorded yet.'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets); // the frame still exists
  });

  testWidgets('a populated burn history paints the sparkline', (tester) async {
    await tester.pumpWidget(
      _host(
        budget: _budget(
          history: const [
            BudgetHistorySlot(mine: 3, others: 1),
            BudgetHistorySlot(mine: 4, others: 2),
          ],
        ),
        controller: PreferencesController.ephemeral(),
      ),
    );
    await _openPopover(tester);
    await tester.tap(find.byKey(kBudgetHistoryPillKey));
    await tester.pumpAndSettle();
    expect(find.text('No activity recorded yet.'), findsNothing);
  });

  testWidgets('the legend says its totals span every bucket', (tester) async {
    // Summed across buckets the totals can exceed any single 5,000 limit -- a
    // bare "5,001" beside per-bucket bars reads as an impossible number.
    await tester.pumpWidget(_host(budget: _budget()));
    await _openPopover(tester);
    expect(find.text('across all buckets'), findsOneWidget);
  });

  testWidgets('the no-auth state offers the one actionable next step', (
    tester,
  ) async {
    // Without a token there is nothing to report, so the only useful content is
    // how to fix it. Copyable text, not a button -- makit does not run auth.
    await tester.pumpWidget(_host(budget: null));
    await _openPopover(tester);
    expect(find.byKey(kBudgetAuthHintKey), findsOneWidget);
    expect(find.text('gh auth login'), findsOneWidget);
  });

  test('the sparkline plots other-tool spend, not the cumulative total', () {
    // The violet line is labelled "other tools on the same token" -- the whole
    // insight of the panel. Plotting mine+others there would always sit above
    // the amber line and attribute total burn to somebody else, teaching
    // exactly the wrong mental model. Asserted on the geometry the painter
    // actually draws, not on a parallel helper.
    const history = [
      BudgetHistorySlot(mine: 10, others: 1),
      BudgetHistorySlot(mine: 10, others: 1),
    ];
    const size = Size(110, 40);
    final paths = buildSparklinePaths(history, size);

    // peak = mine+others = 11, so `mine` sits at 10/11 of the height and
    // `others` at 1/11. In canvas coords y grows downward, so others is LOWER
    // on screen (a larger y) -- and a cumulative series would land at y == 0.
    expect(paths.mine.getBounds().top, closeTo(40 - (10 / 11) * 40, 0.01));
    expect(paths.others.getBounds().top, closeTo(40 - (1 / 11) * 40, 0.01));
    expect(
      paths.others.getBounds().top,
      greaterThan(paths.mine.getBounds().top),
      reason:
          'the other-tools line must sit below the makit line, not above it',
    );
  });
}

/// Records the budget commands the popover fires, so the controls are proven
/// live rather than decorative. Everything else falls through to the real
/// controller.
class _SpyStoreController extends StoreController {
  _SpyStoreController(super.ref, this._onCmd);
  final void Function(String kind) _onCmd;

  @override
  Future<void> refreshGithubBudget() async => _onCmd('github.refresh');

  @override
  Future<void> setGithubPollingPaused(bool paused) async =>
      _onCmd('github.pause');
}
