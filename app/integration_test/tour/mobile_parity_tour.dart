// A driven walkthrough of the mobile changes on this branch, for screen capture.
//
// Not an assertion suite — it is a *camera path*. It enters demo mode and then
// visits, in order: the repo card's collapse, the "Show N more" cut, a
// session-less branch with its age, a worktree fold, the archived screen, the
// session PR chip + sheet, and composer draft survival across a route pop.
// Each step holds still for [_beat] so the recording is watchable, and asserts
// just enough that a silently broken step fails the run instead of filming a
// blank screen.
//
// Run under `tool/record-tour.sh`, which films the simulator while this drives.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:makit/main.dart' as app;

/// How long each step lingers so the camera catches it.
const _beat = Duration(milliseconds: 1400);

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
  final texts = find
      .byType(Text)
      .evaluate()
      .map((e) => (e.widget as Text).data ?? '<rich>')
      .where((s) => s.isNotEmpty)
      .toList();
  fail('timed out waiting for $finder\nvisible text:\n  ${texts.join('\n  ')}');
}

Future<void> tapAndHold(WidgetTester tester, Finder finder) async {
  await tester.tap(finder.first, warnIfMissed: false);
  await hold(tester);
}

/// Walk onboarding into demo mode: dismiss the notifications gate if it shows,
/// then take the "Open with fake data" door. Done when a repo card is on screen.
///
/// A simulator that has run the e2e suite keeps paired credentials in the
/// keychain (an app uninstall does not clear it), so the app may boot straight
/// to a Home bound to a dead server. From there the route to the demo is
/// Settings → "Unpair this device", which is also the one a real user has.
Future<void> enterDemoMode(WidgetTester tester) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  var unpaired = false;
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 80));
    // Home *with demo data* is up once a demo repo card is rendered ('cmux' is a
    // repo name only, unlike 'makit' which is also the app title).
    if (find.text('cmux').evaluate().isNotEmpty) return;

    final fake = find.text('Open with fake data');
    if (fake.evaluate().isNotEmpty) {
      await tester.tap(fake.first, warnIfMissed: false);
      await hold(tester, const Duration(milliseconds: 600));
      continue;
    }
    final notNow = find.text('Not now');
    if (notNow.evaluate().isNotEmpty) {
      await tester.tap(notNow.first, warnIfMissed: false);
      await hold(tester, const Duration(milliseconds: 600));
      continue;
    }
    // Stale pairing: unpair once, which returns to the pairing screen.
    final unpair = find.text('Unpair this device');
    if (unpair.evaluate().isNotEmpty) {
      await tester.tap(unpair.first, warnIfMissed: false);
      unpaired = true;
      await hold(tester, const Duration(milliseconds: 800));
      continue;
    }
    // On Settings, but Unpair is the last row and a ListView does not build
    // what is off-screen — scroll it into existence. Drag the scrollable, not a
    // label: the first drag pushes any label off screen, after which anchoring
    // on one leaves the loop spinning.
    if (find.text('WORKSPACE').evaluate().isNotEmpty ||
        find.text('CONNECTION').evaluate().isNotEmpty ||
        find.text('APPEARANCE').evaluate().isNotEmpty) {
      final scrollable = find.byType(Scrollable);
      if (scrollable.evaluate().isNotEmpty) {
        await tester.drag(scrollable.last, const Offset(0, -400));
        await hold(tester, const Duration(milliseconds: 250));
        continue;
      }
    }
    final settings = find.byTooltip('Settings');
    if (!unpaired && settings.evaluate().isNotEmpty) {
      await tester.tap(settings.first, warnIfMissed: false);
      await hold(tester, const Duration(milliseconds: 600));
      continue;
    }
  }
  final texts = find
      .byType(Text)
      .evaluate()
      .map((e) => (e.widget as Text).data ?? '<rich>')
      .where((s) => s.isNotEmpty)
      .toList();
  fail('never reached demo Home\nvisible text:\n  ${texts.join('\n  ')}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mobile parity tour', (tester) async {
    app.main();
    await hold(tester, const Duration(seconds: 2));

    // ---- demo mode ------------------------------------------------------
    // A fresh install lands on onboarding. Depending on notification permission
    // state that is either the notifications gate or the pairing step, so drive
    // whichever is on screen until Home appears rather than assuming an order.
    await enterDemoMode(tester);
    await hold(tester);

    // ---- 1. every worktree is listed, with its age ----------------------
    // A quiet branch with uncommitted work and no session: previously invisible.
    await waitFor(tester, find.text('tidy-composer-spacing'));
    expect(find.text('2d ago'), findsWidgets);
    await hold(tester);

    // ---- 2. "Show N more" past five worktrees ---------------------------
    final showMore = find.textContaining('more');
    await waitFor(tester, showMore);
    await tapAndHold(tester, showMore);
    await waitFor(tester, find.text('old-experiment'));
    expect(find.text('1y ago'), findsWidgets);
    await hold(tester);
    await tapAndHold(tester, find.text('Show less'));

    // ---- 3. fold a worktree's sessions ---------------------------------
    // Asserted, not best-effort: a silently skipped step would film nothing and
    // still report success.
    final caret = find.byKey(
      const Key(
        'worktreeCaret-/Users/le/Work/Vibe/makit/.wt/wire-up-pairing-screen',
      ),
    );
    await waitFor(tester, caret);
    await tapAndHold(tester, caret);
    expect(find.text('wire up pairing screen'), findsNothing);
    await tapAndHold(tester, caret);
    await waitFor(tester, find.text('wire up pairing screen'));

    // ---- 4. collapse the whole repo card -------------------------------
    await tapAndHold(tester, find.text('cmux'));
    expect(find.text('fix tab drag-and-drop'), findsNothing);
    await tapAndHold(tester, find.text('cmux'));

    // ---- 5. archived sessions ------------------------------------------
    await tapAndHold(tester, find.byTooltip('Archived sessions'));
    await waitFor(tester, find.text('draft release notes'));
    await hold(tester, const Duration(seconds: 2));
    await tapAndHold(tester, find.byIcon(PhosphorIconsLight.arrowLeft));
    await waitFor(tester, find.text('makit'));

    // ---- 6. PR chip on the session screen, and the PR sheet ------------
    await tapAndHold(tester, find.text('wire up pairing screen'));
    await waitFor(tester, find.text('#42'));
    await hold(tester);
    await tapAndHold(tester, find.text('#42'));
    await waitFor(tester, find.text('PR #42'));
    await hold(tester, const Duration(seconds: 2));
    // Dismiss the sheet.
    await tapAndHold(tester, find.byTooltip('Close'));

    // ---- 7. composer draft survives leaving the session ---------------
    await tester.enterText(
      find.byType(TextField).last,
      'half-typed message that must survive',
    );
    await hold(tester);
    await tapAndHold(tester, find.byIcon(PhosphorIconsLight.arrowLeft));
    await waitFor(tester, find.text('makit'));
    await hold(tester);
    await tapAndHold(tester, find.text('wire up pairing screen'));
    await waitFor(tester, find.text('half-typed message that must survive'));
    await hold(tester, const Duration(seconds: 2));
  });
}
