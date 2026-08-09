// Screenshot pass for the ports feature (SPEC-42 P2c → SPEC-44): enters demo
// mode, then walks the surfaces the recent work added, holding still at each one
// so `simctl io screenshot` can capture it. Run via `tool/shoot-ports.sh`.
//
// Not an assertion suite — a *camera path*, like `home_shots.dart`. It drives the
// shipping widgets on the real store (demo mode's in-process server answers
// `ports.kill`, `ports.killOrphans`, `ports.watchPort` and `ports.forward`), so
// what the camera sees is what a user sees.
//
// Each scene prints `SHOT <name>` and then holds, which is the signal the shooter
// script screenshots on. A `hold` pumps real frames rather than fast-forwarding
// the clock, because `pumpAndSettle` would skip the animation the shot is of.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:makit/main.dart' as app;
import 'package:makit/ui/ports/ports_glyph.dart';
import 'package:makit/ui/ports/ports_screen.dart';
import 'package:makit/ui/ports/ports_vocabulary.dart';

import 'mobile_parity_tour.dart' show enterDemoMode, hold, waitFor;

/// Long enough that the shooter's screenshot lands inside the hold.
const _shot = Duration(seconds: 5);

Future<void> shot(WidgetTester tester, String name) async {
  debugPrint('SHOT $name');
  await hold(tester, _shot);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ports surfaces hold still for screenshots', (tester) async {
    app.main();
    await hold(tester, const Duration(seconds: 2));
    await enterDemoMode(tester);
    await waitFor(tester, find.byType(PortsGlyph));

    // ── 1. the worktree row's glyph, then the port list (sheet 1) ──────────
    await shot(tester, '01-home-glyph');

    await tester.tap(find.byType(PortsGlyph).first, warnIfMissed: false);
    await waitFor(tester, find.byKey(const ValueKey('ports-list-row-5173')));
    await shot(tester, '02-sheet-list');

    // ── 2. the detail sheet: watch toggle + Open in browser + Kill ─────────
    await tester.tap(find.byKey(const ValueKey('ports-list-row-5173')));
    await waitFor(tester, find.text('command'));
    await shot(tester, '03-sheet-detail');

    // Scroll the sheet so the danger zone is in frame.
    await tester.drag(find.text('command'), const Offset(0, -260));
    await hold(tester, const Duration(milliseconds: 600));
    await shot(tester, '04-sheet-danger-zone');

    // ── 3. the kill confirm (D8): it names the victim ──────────────────────
    final killRow = find.text(portKillRowLabel);
    if (killRow.evaluate().isNotEmpty) {
      await tester.tap(killRow.first, warnIfMissed: false);
      await waitFor(tester, find.textContaining('SIGTERM'));
      await shot(tester, '05-kill-confirm');
      await tester.tap(find.text('Cancel'), warnIfMissed: false);
      await hold(tester, const Duration(milliseconds: 600));
    }

    // ── 4. the browser hand-off confirm (SPEC-44 P4b) ──────────────────────
    final forward = find.text(portForwardLabel);
    if (forward.evaluate().isNotEmpty) {
      await tester.tap(forward.first, warnIfMissed: false);
      await waitFor(tester, find.textContaining('certificate'));
      await shot(tester, '06-forward-confirm');
      await tester.tap(find.text('Cancel'), warnIfMissed: false);
      await hold(tester, const Duration(milliseconds: 600));
    }

    // Close the two sheets.
    for (var i = 0; i < 2; i++) {
      final nav = Navigator.of(tester.element(find.byType(Scaffold).first));
      if (nav.canPop()) nav.pop();
      await hold(tester, const Duration(milliseconds: 500));
    }

    // ── 5. the global Ports screen: docker row + orphans + bulk kill ───────
    final plug = find.byIcon(Icons.settings_ethernet);
    if (plug.evaluate().isEmpty) {
      // The home app bar's ports button is a phosphor plug; find it by tooltip.
      final byTooltip = find.byTooltip('Ports');
      if (byTooltip.evaluate().isNotEmpty) {
        await tester.tap(byTooltip.first, warnIfMissed: false);
      }
    }
    await hold(tester, const Duration(seconds: 1));
    if (find.byType(PortsScreen).evaluate().isEmpty) {
      debugPrint('SHOT_SKIP ports-screen (no entry point found from home)');
    } else {
      await waitFor(tester, find.text('OTHER / SYSTEM'));
      await shot(tester, '07-ports-screen');

      // The docker-published port lives in the system group, which is folded by
      // default ("noise, not work"). Unfold it: the row must name the CONTAINER
      // rather than `com.docker.backend`, and still read `exposed` (SPEC-42 D13).
      await tester.tap(find.text('OTHER / SYSTEM'), warnIfMissed: false);
      await waitFor(tester, find.text('chat-ui-db-1'));
      await shot(tester, '07b-docker-row');

      // Scroll to the orphans section and its bulk-kill button.
      await tester.drag(find.byType(PortsScreen), const Offset(0, -320));
      await hold(tester, const Duration(milliseconds: 600));
      await shot(tester, '08-orphans-section');

      final killAll = find.byKey(kPortsKillAllOrphans);
      if (killAll.evaluate().isNotEmpty) {
        await tester.tap(killAll.first, warnIfMissed: false);
        await waitFor(tester, find.text('Kill all'));
        await shot(tester, '09-kill-all-confirm');
        await tester.tap(find.text('Kill all'), warnIfMissed: false);
        await hold(tester, const Duration(seconds: 2));
        await shot(tester, '10-orphans-killed');
      }
    }

    debugPrint('SHOT DONE');
  });
}
