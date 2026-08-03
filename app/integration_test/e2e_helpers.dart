import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/main.dart' as app;

const _connectionTimeout = Duration(seconds: 20);
const _messageTimeout = Duration(seconds: 15);

/// Boot the app, wait until the home screen has hydrated from the test server.
///
/// "Hydrated" = the project tile (named after the basename of the --project
/// path the test server was launched with, i.e. "makit") is visible. By that
/// point the WS handshake has completed and the snapshot has arrived.
Future<void> launchMakit(WidgetTester tester) async {
  app.main();
  await tester.pump(const Duration(milliseconds: 100));
  // The test creds are seeded as paired, so onboarding skips the pair step —
  // but on a fresh simulator notification permission is notDetermined, so the
  // wizard now stops at the skippable notifications gate before Home. Dismiss
  // it ("Not now") so the suite reaches the session list as before.
  await _skipNotificationsStep(tester);
  await pumpUntil(
    tester,
    find.text('new session'),
    timeout: _connectionTimeout,
    reason:
        'home screen never showed the "new session" tile — '
        'WS handshake or snapshot likely failed',
  );
}

/// Dismiss the notifications onboarding gate if it's showing. No-op once the
/// app has already advanced past it, so it's safe to call unconditionally.
Future<void> _skipNotificationsStep(WidgetTester tester) async {
  final skip = find.widgetWithText(TextButton, 'Not now');
  final deadline = DateTime.now().add(_connectionTimeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (skip.evaluate().isNotEmpty) {
      await tester.tap(skip);
      await tester.pump(const Duration(milliseconds: 100));
      return;
    }
    // Already past the gate (session list rendering) — nothing to skip.
    if (find.text('new session').evaluate().isNotEmpty) return;
  }
}

/// Open the first session in the list (the stub server pre-creates one
/// "new session" entry).
Future<void> openFirstSession(WidgetTester tester) async {
  final sessionTile = find.widgetWithText(ListTile, 'new session').first;
  await pumpUntil(tester, sessionTile, reason: 'no "new session" tile found');
  await tester.tap(sessionTile);
  await tester.pumpAndSettle();
  await pumpUntil(tester, find.byType(TextField));
}

/// Type [text] into the composer and tap the send button.
Future<void> sendComposerText(WidgetTester tester, String text) async {
  final field = find.byType(TextField).last;
  // Tap first: `_send()` unfocuses the composer, so on the SECOND send in a
  // test `enterText` runs against an unfocused field and, under the live
  // integration binding, silently leaves the text empty (verified — the send
  // button then never appears). A tap restores focus and the input connection.
  await tester.tap(field);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.enterText(field, text);
  await tester.pump();
  // Target the send button by key, not by icon. Two arrowUp icons exist in the
  // composer's AnimatedSwitcher (ValueKey('send') and ValueKey('send-disabled'),
  // the latter a no-op with onPressed: null) and they overlap mid-crossfade, so
  // an icon finder is both ambiguous and render-order dependent.
  await tester.tap(find.byKey(const ValueKey('send')));
  await tester.pump(const Duration(milliseconds: 100));
}

/// Pump the widget tree at 100ms steps until [finder] matches OR the timeout
/// expires. Throws a TestFailure with [reason] on timeout (so failures point
/// at the assertion site, not a deep stack).
Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = _messageTimeout,
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) {
      // Settle one more frame so a mid-build match is fully laid out before
      // the caller asserts against it (avoids flaky partial-frame matches).
      await tester.pump(const Duration(milliseconds: 100));
      return;
    }
  }
  // Dump every Text widget currently visible so we can diagnose the failure
  // without re-running with a debugger attached.
  final visibleTexts = find
      .byType(Text)
      .evaluate()
      .map((e) => (e.widget as Text).data ?? '<rich>')
      .where((s) => s.isNotEmpty)
      .toList();
  fail(
    '${reason ?? 'pumpUntil timed out waiting for: $finder'}\n'
    'After ${timeout.inSeconds}s, visible Text widgets were:\n'
    '  ${visibleTexts.join('\n  ')}',
  );
}

/// Navigate from a session to the phone's Settings screen and back.
///
/// Used by the queue tour (SPEC-36) to film the placement preference moving the
/// pending queue between the composer and the transcript. Goes via Home because
/// that is the only route with a Settings entry point — filming the real path a
/// user takes is the point of a tour.
Future<void> openSettings(WidgetTester tester) async {
  // Leave the session. Neither back control is a Material/Cupertino back button
  // (`pageBack()` fails, and there is no 'Back' tooltip): the session screen's
  // is a GlassCircleButton and Settings' an IconButton, both drawn with the
  // same arrowLeft glyph — so tap the glyph.
  await tapBack(tester);
  final gear = find.byTooltip('Settings');
  await pumpUntil(tester, gear, reason: 'no Settings button on Home');
  await tester.tap(gear.first);
  await tester.pump(const Duration(milliseconds: 500));
}

/// Return from Settings to the first session.
Future<void> closeSettings(WidgetTester tester) async {
  await tapBack(tester);
}

/// Re-open a session by a fragment of the text on its home-screen tile.
///
/// Not [openFirstSession]: once a session has a message it is no longer a draft,
/// so its tile is titled after the conversation instead of "new session" — and
/// tapping "new session" would open a *different* (empty) session.
Future<void> openSessionContaining(WidgetTester tester, String text) async {
  final tile = find
      .ancestor(of: find.textContaining(text), matching: find.byType(ListTile))
      .first;
  await pumpUntil(tester, tile, reason: 'no session tile matching "$text"');
  await tester.tap(tile);
  // NOT pumpAndSettle: while a turn is running the working indicator animates
  // forever, so settling would block until the agent finished — long enough for
  // the very queue we came back to look at to flush.
  await tester.pump(const Duration(milliseconds: 400));
  await pumpUntil(tester, find.byType(TextField));
}

/// Tap the screen's back affordance (arrowLeft glyph) and let the route settle.
Future<void> tapBack(WidgetTester tester) async {
  final back = find.byIcon(PhosphorIconsLight.arrowLeft);
  await pumpUntil(tester, back, reason: 'no back arrow on screen');
  await tester.tap(back.first);
  await tester.pump(const Duration(milliseconds: 400));
}
