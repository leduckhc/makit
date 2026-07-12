import 'package:flutter/material.dart';
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
  await tester.enterText(find.byType(TextField).last, text);
  await tester.pump();
  await tester.tap(find.byIcon(Icons.arrow_upward));
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
