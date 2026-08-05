// A driven walkthrough of the mobile redesign on this branch, for screen capture.
//
// Not an assertion suite — it is a *camera path*. It films, in order: the
// rebuilt connect screen (the single server surface), the status-forward repo
// card with its accent bars, a per-worktree "+" opening the new-session sheet
// already pointed at that branch, the card-level "New worktree" action, the
// repo-card collapse, and a session.
//
// Each step holds still for [_beat] so the recording is watchable, and asserts
// just enough that a silently broken step fails the run instead of filming a
// blank screen.
//
// Run under `tool/record-tour.sh /tmp/mobile-redesign-tour.mp4 integration_test/tour/redesign_tour.dart`.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:makit/main.dart' as app;

/// How long each step lingers so the camera catches it.
const _beat = Duration(milliseconds: 1500);

/// Real (wall-clock) settle: `pumpAndSettle` fast-forwards time in a way that
/// makes the recording jump, so the tour pumps frames for a real duration.
Future<void> hold(WidgetTester tester, [Duration d = _beat]) async {
  final deadline = DateTime.now().add(d);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 32));
  }
}

Future<void> waitFor(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 60));
    if (finder.evaluate().isNotEmpty) {
      await tester.pump(const Duration(milliseconds: 120));
      return;
    }
  }
  fail('timed out waiting for $finder\n${_visibleText()}');
}

String _visibleText() {
  final texts = find
      .byType(Text)
      .evaluate()
      .map((e) => (e.widget as Text).data ?? '<rich>')
      .where((s) => s.isNotEmpty)
      .toList();
  return 'visible text:\n  ${texts.join('\n  ')}';
}

Future<void> tapAndHold(
  WidgetTester tester,
  Finder finder, [
  Duration d = _beat,
]) async {
  await tester.tap(finder.first, warnIfMissed: false);
  await hold(tester, d);
}

/// Walk onboarding into demo mode via the connect screen's demo door.
///
/// The recorder resets the keychain first, so the expected path is a clean first
/// run: notifications gate (maybe) → connect screen → "Open with fake data".
/// Stale pairing is still handled, because the keychain reset can be refused —
/// and that path now goes through the unpair confirmation this branch added.
Future<void> enterDemoMode(WidgetTester tester) async {
  final deadline = DateTime.now().add(const Duration(seconds: 90));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 80));
    // Home *with demo data* is up once a demo repo card is rendered ('cmux' is
    // a repo name only, unlike 'makit' which is also the app title).
    if (find.text('cmux').evaluate().isNotEmpty) return;

    // Order matters. The unpair *confirmation* must be handled before the row
    // that opens it: the row stays in the tree behind the dialog, so checking it
    // first taps it forever and never reaches the confirm button.
    final steps = <Finder>[
      find.widgetWithText(FilledButton, 'Unpair'), // the confirmation
      find.text('Open with fake data'), // the demo door
      find.text('Not now'), // notifications gate
      find.text('Unpair this device'), // stale single pairing
      find.textContaining('Unpair from all'), // stale multi pairing
      find.byTooltip('Settings'), // from Home, to reach unpair
    ];
    var acted = false;
    for (final f in steps) {
      if (f.evaluate().isNotEmpty) {
        await tester.tap(f.first, warnIfMissed: false);
        await hold(tester, const Duration(milliseconds: 500));
        acted = true;
        break;
      }
    }
    if (acted) continue;

    // On Settings with the unpair row not yet built: a ListView does not build
    // what is off-screen, so scroll it into existence.
    final scrollable = find.byType(Scrollable);
    if (scrollable.evaluate().isNotEmpty) {
      await tester.drag(scrollable.last, const Offset(0, -400));
      await hold(tester, const Duration(milliseconds: 250));
    }
  }
  fail('never reached demo Home\n${_visibleText()}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mobile redesign tour', (tester) async {
    app.main();
    await hold(tester, const Duration(seconds: 2));

    // ---- 1. the connect screen: one surface for servers -----------------
    // Hero + a single primary action + the demo door. Dwell here deliberately:
    // the screen only exists for the second it takes the tour to tap through,
    // so waiting *for* it (rather than checking once) is what puts it on film.
    final connect = find.text('Connect to your Mac');
    final onConnect = DateTime.now().add(const Duration(seconds: 25));
    while (DateTime.now().isBefore(onConnect)) {
      await tester.pump(const Duration(milliseconds: 60));
      if (connect.evaluate().isNotEmpty) break;
      // A notifications gate can sit in front of it on a fresh simulator.
      final notNow = find.text('Not now');
      if (notNow.evaluate().isNotEmpty) {
        await tester.tap(notNow.first, warnIfMissed: false);
        await hold(tester, const Duration(milliseconds: 400));
      }
      // Already paired (keychain survived): skip ahead, enterDemoMode copes.
      if (find.text('cmux').evaluate().isNotEmpty) break;
    }
    if (connect.evaluate().isNotEmpty) {
      await hold(tester, const Duration(seconds: 4));
      // Scroll so "Add server" and the demo card are both framed.
      final sc = find.byType(Scrollable);
      if (sc.evaluate().isNotEmpty) {
        await tester.drag(sc.first, const Offset(0, -140));
        await hold(tester, const Duration(seconds: 2));
      }
    }

    // ---- 2. into demo mode ---------------------------------------------
    await enterDemoMode(tester);
    await hold(tester, const Duration(seconds: 2));

    // ---- 3. status-forward cards: accent bars --------------------------
    // The claude session in `cmux` is `running`, so its worktree carries a green
    // accent bar; a quiet branch carries none. Both are on this screen.
    await waitFor(tester, find.text('cmux'));
    await waitFor(tester, find.text('fix tab drag-and-drop'));
    expect(find.byType(Divider), findsNothing); // solid card, no hairline rows
    await hold(tester, const Duration(seconds: 3));

    // Scroll the list so the second repo card and the quiet branches show.
    final list = find.byType(Scrollable).first;
    await tester.drag(list, const Offset(0, -260));
    await hold(tester, const Duration(seconds: 2));
    await tester.drag(list, const Offset(0, 260));
    await hold(tester);

    // ---- 4. per-worktree "+": a session on *this* branch ---------------
    // The affordance that was missing entirely: the sheet opens already pointed
    // at the branch whose row was tapped, so the worktree is not asked twice.
    final plus = find.byKey(
      const Key(
        'newSessionInWorktree-/Users/le/Work/Vibe/makit/.wt/wire-up-pairing-screen',
      ),
    );
    await waitFor(tester, plus);
    await tapAndHold(tester, plus, const Duration(seconds: 3));
    await waitFor(tester, find.text('Start'));
    await hold(tester, const Duration(seconds: 2));
    // Leave without spawning — the tour films the door, it does not walk in.
    await tester.tapAt(const Offset(200, 60));
    await hold(tester);

    // ---- 5. the card-level action is "New worktree" --------------------
    final newWorktree = find.text('New worktree');
    await waitFor(tester, newWorktree);
    await tapAndHold(tester, newWorktree, const Duration(seconds: 2));
    await waitFor(tester, find.text('New worktree from…'));
    await hold(tester, const Duration(seconds: 2));
    await tester.tapAt(const Offset(200, 60));
    await hold(tester);

    // ---- 6. collapse a whole repo card --------------------------------
    await tapAndHold(tester, find.text('cmux'));
    expect(find.text('fix tab drag-and-drop'), findsNothing);
    await tapAndHold(tester, find.text('cmux'));
    await waitFor(tester, find.text('fix tab drag-and-drop'));

    // ---- 7. a session ------------------------------------------------
    await tapAndHold(tester, find.text('wire up pairing screen'));
    await hold(tester, const Duration(seconds: 3));
    await tapAndHold(tester, find.byIcon(PhosphorIconsLight.arrowLeft));
    await hold(tester, const Duration(seconds: 2));
  });
}
