// SPEC-52 A3 + A4 — the identity panel: its rows, its ONE copy affordance, its
// read-only-ness, its accessibility, and the two hosts it renders in.
//
// The single-copy-affordance test (D5) is the load-bearing one: four per-row
// copy buttons were designed, measured, and superseded, and this test is what
// stops them coming back.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/status/status_center.dart';
import 'package:makit/status/status_event.dart';
import 'package:makit/status/status_providers.dart';
import 'package:makit/ui/session/session_identity.dart';

const kId = '019fa9f4-443d-7d86-8f4c-d9c4988ddf4f';
const kPath =
    '/Users/le/.pi/agent/sessions/--Users-le-.worktrees-makit-feat-get-session-id--/'
    '2026-08-11T14-01-46-945Z_019ff121-1cc1-7c60-bc40-65890c87e6ff.jsonl';
const kMakitId = '7c9e6d5a-1f42-4b8e-9a01-2d3f4e5a6b7c';

SessionIdentity identity({
  String agent = 'pi',
  String? agentSessionId = kId,
  String? transcriptPath = kPath,
}) => SessionIdentity.from(
  agent: agent,
  makitSessionId: kMakitId,
  agentSessionId: agentSessionId,
  transcriptPath: transcriptPath,
);

/// Captures what the panel actually puts on the clipboard, and can be made to
/// fail so the "never toast success on a failed write" rule is testable.
class _Clipboard {
  final List<String> writes = [];
  bool fail = false;

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          if (fail) throw PlatformException(code: 'denied');
          writes.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
  }

  void remove(WidgetTester tester) => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null);
}

Widget _host(Widget child, {StatusCenter? status}) => ProviderScope(
  overrides: [
    if (status != null) statusCenterProvider.overrideWithValue(status),
  ],
  child: MaterialApp(
    theme: makitDarkTheme,
    home: Scaffold(body: child),
  ),
);

void main() {
  late _Clipboard clipboard;

  setUp(() => clipboard = _Clipboard());

  group('A3 — the body (D5, D8, D9, D18)', () {
    testWidgets('renders one row per measured value', (tester) async {
      await tester.pumpWidget(
        _host(SessionIdentityDetails(identity: identity())),
      );
      expect(find.text('pi session'), findsOneWidget);
      expect(find.text('Transcript'), findsOneWidget);
      expect(find.text('Resume with'), findsOneWidget);
      expect(find.text('makit session'), findsOneWidget);
      expect(find.text(kId), findsOneWidget);
    });

    testWidgets('rows appear in the locked order, top to bottom', (
      tester,
    ) async {
      // Asserted by painted position, not by mere presence: "in order" is only
      // a real assertion if reversing the list can fail it.
      await tester.pumpWidget(
        _host(SessionIdentityDetails(identity: identity())),
      );
      double dy(String label) => tester.getTopLeft(find.text(label)).dy;
      expect(dy('pi session'), lessThan(dy('Transcript')));
      expect(dy('Transcript'), lessThan(dy('Resume with')));
      expect(dy('Resume with'), lessThan(dy('makit session')));
    });

    testWidgets('D9 — an absent transcript renders NO row, not a blank one', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(SessionIdentityDetails(identity: identity(transcriptPath: null))),
      );
      expect(find.text('Transcript'), findsNothing);
      expect(find.text('pi session'), findsOneWidget);
    });

    testWidgets('D9 — an unknown agent renders no resume row', (tester) async {
      await tester.pumpWidget(
        _host(SessionIdentityDetails(identity: identity(agent: 'stub'))),
      );
      expect(find.text('Resume with'), findsNothing);
      expect(find.text('Agent session'), findsOneWidget);
    });

    testWidgets('a draft says so, and offers no id or resume row', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SessionIdentityDetails(
            identity: identity(agentSessionId: null, transcriptPath: null),
          ),
        ),
      );
      expect(find.text(kSessionIdentityNoAgentLine), findsOneWidget);
      expect(find.text('Resume with'), findsNothing);
      expect(find.text('makit session'), findsOneWidget);
    });

    testWidgets('D5 — there is exactly ONE copy affordance', (tester) async {
      await tester.pumpWidget(
        _host(SessionIdentityDetails(identity: identity())),
      );
      expect(
        find.byIcon(kSessionIdentityCopyIcon),
        findsOneWidget,
        reason:
            'four per-row buttons were designed and superseded: they cost 116px '
            'of value width (wrapping a uuid mid-string) and a toast that '
            'cannot say which one was hit',
      );
    });

    testWidgets('Copy all copies exactly sessionIdentityText', (tester) async {
      clipboard.install(tester);
      addTearDown(() => clipboard.remove(tester));
      final id = identity();
      await tester.pumpWidget(_host(SessionIdentityDetails(identity: id)));
      await tester.tap(find.byIcon(kSessionIdentityCopyIcon));
      await tester.pumpAndSettle();
      expect(clipboard.writes, [sessionIdentityText(id)]);
    });

    testWidgets('a failed clipboard write does not claim success', (
      tester,
    ) async {
      // Asserted against the STATUS BUS, not against rendered text: the test
      // host has no toast overlay, so a `findsNothing` on rendered text could
      // never fail and the test would be vacuous. (It was, in the first draft —
      // the mutation "toast unconditionally" did not bite until this changed.)
      clipboard
        ..install(tester)
        ..fail = true;
      addTearDown(() => clipboard.remove(tester));
      final status = StatusCenter();
      await tester.pumpWidget(
        _host(SessionIdentityDetails(identity: identity()), status: status),
      );
      await tester.tap(find.byIcon(kSessionIdentityCopyIcon));
      await tester.pumpAndSettle();
      expect(clipboard.writes, isEmpty);
      expect(
        status.events.map((e) => e.title),
        isNot(contains('Session details copied')),
      );
      final failed = status.events.where(
        (e) => e.title == 'Could not copy session details',
      );
      expect(failed, hasLength(1));
      expect(
        failed.single.severity,
        StatusSeverity.failure,
        reason: 'all three copy paths report a failed write the same way',
      );
    });

    testWidgets('a successful copy posts exactly one confirmation', (
      tester,
    ) async {
      clipboard.install(tester);
      addTearDown(() => clipboard.remove(tester));
      final status = StatusCenter();
      await tester.pumpWidget(
        _host(SessionIdentityDetails(identity: identity()), status: status),
      );
      await tester.tap(find.byIcon(kSessionIdentityCopyIcon));
      await tester.pumpAndSettle();
      expect(
        status.events.where((e) => e.title == 'Session details copied'),
        hasLength(1),
      );
    });

    testWidgets('D8 — read-only: no field, no destructive affordance', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(SessionIdentityDetails(identity: identity())),
      );
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(EditableText), findsNothing);
      final destructive = RegExp(
        r'rename|delete|close session|kill|quit',
        caseSensitive: false,
      );
      for (final w in tester.widgetList<Text>(find.byType(Text))) {
        final data = w.data ?? '';
        expect(
          destructive.hasMatch(data),
          isFalse,
          reason:
              'lifecycle lives in the menu, not one mis-tap from a copy row',
        );
      }
    });

    testWidgets('D18 — the copy row names its payload for a screen reader', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(SessionIdentityDetails(identity: identity())),
      );
      // Names WHAT it copies and HOW MUCH: a screen-reader user cannot see the
      // toast, so the affordance must say it before the tap.
      expect(
        find.bySemanticsLabel(RegExp(r'Copy session details.*4 lines')),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('D18 — a value row exposes its label and value together', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(SessionIdentityDetails(identity: identity())),
      );
      expect(find.bySemanticsLabel(RegExp('pi session.*$kId')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a one-line payload says "1 line", not "1 lines"', (
      tester,
    ) async {
      // Reachable in production: a stub/detached session has no agent id and no
      // transcript, so the makit id is the only measured value. The first build
      // read "1 lines" and the pixel gate on the real macOS app caught it.
      final lone = identity(
        agent: 'stub',
        agentSessionId: null,
        transcriptPath: null,
      );
      expect(sessionIdentityText(lone).split('\n'), hasLength(1));
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(SessionIdentityDetails(identity: lone)));
      expect(find.text('1 line'), findsOneWidget);
      expect(find.text('1 lines'), findsNothing);
      expect(
        find.bySemanticsLabel('Copy session details, 1 line'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('a multi-line payload still pluralises', (tester) async {
      await tester.pumpWidget(
        _host(SessionIdentityDetails(identity: identity())),
      );
      expect(find.text('4 lines'), findsOneWidget);
    });

    testWidgets('values are monospaced', (tester) async {
      await tester.pumpWidget(
        _host(SessionIdentityDetails(identity: identity())),
      );
      final text = tester.widget<Text>(find.text(kId));
      expect(text.style?.fontFamily, kMonoFontFamily);
    });
  });

  group('A4 — the hosts (D11, D19)', () {
    testWidgets('mobile opens a bottom sheet', (tester) async {
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showSessionIdentity(
                context: context,
                identity: identity(),
                desktop: false,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text(kId), findsOneWidget);
    });

    testWidgets('desktop opens a centred, window-clamped panel — not a sheet', (
      tester,
    ) async {
      // The desktop host had NO test at all: every case here passed
      // `desktop: false`, which is how the panel came to be documented as an
      // "anchored MenuAnchor popover" (D11) while shipping a centred dialog. It
      // is centred on purpose — both desktop doors are transient MENU ITEMS, so
      // by the time one is chosen the menu is gone and there is nothing left on
      // screen to anchor to (unlike SPEC-37's ContextUsageButton, a persistent
      // control in the composer). This test pins the presentation that actually
      // ships, so the doc and the code cannot drift apart again.
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showSessionIdentity(
                context: context,
                identity: identity(),
                desktop: true,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(SessionIdentityDetails), findsOneWidget);
      // Centred: the panel's centre sits on the window's centre, both axes.
      final panel = tester.getRect(find.byType(SessionIdentityDetails));
      expect(panel.center.dx, moreOrLessEquals(700, epsilon: 1));
      expect(panel.center.dy, moreOrLessEquals(450, epsilon: 1));
      // Window-clamped, never wider than the fixed panel width (SPEC-37).
      expect(panel.width, lessThanOrEqualTo(kIdentityPanelWidth));
    });

    testWidgets('a desktop panel in a narrow window is clamped to the window', (
      tester,
    ) async {
      // The SPEC-37 lesson for the desktop host: a fixed-width panel opened from
      // a narrow split pane hung off-screen. 300pt is narrower than the panel's
      // 340pt, so the clamp is what keeps both margins.
      tester.view.physicalSize = const Size(300, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showSessionIdentity(
                context: context,
                identity: identity(),
                desktop: true,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final panel = tester.getRect(find.byType(SessionIdentityDetails));
      expect(panel.left, greaterThanOrEqualTo(0));
      expect(panel.right, lessThanOrEqualTo(300));
      expect(panel.width, lessThanOrEqualTo(300 - 2 * 12));
    });

    testWidgets('a window shrunk below the margins does not throw', (
      tester,
    ) async {
      // `window.width - 2 * margin` goes NEGATIVE below 24pt, and a BoxConstraints
      // whose maxWidth is negative is not normalized: the layout ASSERTS
      // ("BoxConstraints has both width and height constraints non-normalized")
      // instead of rendering a small panel.
      //
      // Reproduced by shrinking the window WHILE the panel is open, which is both
      // the realistic path (a resize animation or an embedded host hands us one
      // degenerate frame) and the only one that works: opening at 20x20 leaves the
      // trigger button unhittable, so the tap lands on nothing and the panel never
      // opens — a test that passes while asserting nothing.
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showSessionIdentity(
                context: context,
                identity: identity(),
                desktop: true,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(SessionIdentityDetails), findsOneWidget);
      tester.view.physicalSize = const Size(20, 20);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'at 320x360 nothing paints off-screen and Copy all is still reachable',
      (tester) async {
        // The SPEC-37 lesson, asserted as the invariant that actually matters.
        // Content TALLER than the window is fine — it scrolls; the transcript
        // path legitimately wraps to four lines on a 320pt phone. What must never
        // happen is the sheet painting outside the window, or the one affordance
        // you opened the panel for being unreachable.
        clipboard.install(tester);
        addTearDown(() => clipboard.remove(tester));
        tester.view.physicalSize = const Size(320, 360);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final id = identity();
        await tester.pumpWidget(
          _host(
            Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showSessionIdentity(
                  context: context,
                  identity: id,
                  desktop: false,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        final sheet = tester.getRect(find.byType(BottomSheet));
        expect(sheet.left, greaterThanOrEqualTo(0));
        expect(sheet.right, lessThanOrEqualTo(320));
        expect(sheet.bottom, lessThanOrEqualTo(360));

        await tester.scrollUntilVisible(
          find.byIcon(kSessionIdentityCopyIcon),
          80,
          scrollable: find.descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(Scrollable),
          ),
        );
        await tester.tap(find.byIcon(kSessionIdentityCopyIcon));
        await tester.pumpAndSettle();
        expect(clipboard.writes, [sessionIdentityText(id)]);
      },
    );

    testWidgets('passing both sessionId and identity is a programming error', (
      tester,
    ) async {
      // The API is exactly-one-of, asserted. The first wiring accepted both and
      // silently ignored `identity`, so every door did a redundant `ref.read`
      // whose result was discarded.
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) =>
                ElevatedButton(onPressed: () {}, child: const Text('x')),
          ),
        ),
      );
      final context = tester.element(find.text('x'));
      expect(
        () => showSessionIdentity(
          context: context,
          desktop: false,
          sessionId: 's1',
          identity: identity(),
        ),
        throwsAssertionError,
      );
      expect(
        () => showSessionIdentity(context: context, desktop: false),
        throwsAssertionError,
      );
    });

    testWidgets(
      'D19 — the panel fills in live when the id arrives while it is open',
      (tester) async {
        // A draft's panel can be opened BEFORE the adapter assigns the id. That
        // assignment fans out a fresh snapshot, so a watching panel must fill
        // in; a snapshotting one would lie until reopened.
        final notifier = ValueNotifier<SessionIdentity>(
          identity(agentSessionId: null, transcriptPath: null),
        );
        addTearDown(notifier.dispose);
        await tester.pumpWidget(
          _host(
            ValueListenableBuilder<SessionIdentity>(
              valueListenable: notifier,
              builder: (_, value, _) => SessionIdentityDetails(identity: value),
            ),
          ),
        );
        expect(find.text(kSessionIdentityNoAgentLine), findsOneWidget);
        expect(find.text(kId), findsNothing);

        notifier.value = identity();
        await tester.pumpAndSettle();

        expect(find.text(kId), findsOneWidget);
        expect(find.text(kSessionIdentityNoAgentLine), findsNothing);
      },
    );
  });
}
