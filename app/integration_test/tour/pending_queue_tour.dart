// A driven walkthrough of the pending-message queue (SPEC-mid-turn-steering-and-queue/36), for screen
// capture.
//
// Not an assertion suite — it is a *camera path*, like
// `mobile_parity_tour.dart`. It runs against the real WSS server with the
// StubAdapter (`tool/record-queue-tour.sh`), so everything on screen is the real
// wire: `send.message`, `queue.update`, `queue.reorder`, `queue.cancel` and the
// sessions snapshot that carries `queued`.
//
// Camera path:
//   1. start a long turn (`SLOW`) so the agent is busy and the queue can exist
//   2. type two more messages — they queue as ghost bubbles above the composer
//   3. reorder them with ↓
//   4. edit one in place, and open the slash palette inside the editor
//   5. cancel one
//   6. switch the presentation to "Compact tray" — mockup variant C
//   7. queue another message and reorder inside the tray
//   8. ⤒ promote: interrupt the running turn so THAT message is sent next, and
//      watch the rest of the queue survive behind it (SPEC-queue-tray-and-promote)
//
// Each step holds still for a beat so the recording is watchable, and asserts
// just enough that a broken step fails the run instead of filming a blank
// screen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:makit/ui/composer/pending_queue.dart';
import 'package:makit/ui/composer/pending_queue_tray.dart';

import '../e2e_helpers.dart';

/// How long each step lingers so the camera catches it.
///
/// Overridable because `simctl io recordVideo` samples the screen at whatever
/// rate the machine allows: with other worktrees running test suites on the same
/// CPU, a 1.6s beat came out as a couple of frames and the whole tour compressed
/// into ~2 seconds of footage. `MAKIT_TOUR_BEAT_MS=3500` buys the recorder time
/// without changing what the tour does.
const _beat = Duration(
  milliseconds: int.fromEnvironment('MAKIT_TOUR_BEAT_MS', defaultValue: 1600),
);

/// Real (wall-clock) settle: `pumpAndSettle` fast-forwards time in a way that
/// makes the recording jump, so the tour pumps frames for a real duration.
Future<void> hold(WidgetTester tester, [Duration d = _beat]) async {
  final deadline = DateTime.now().add(d);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 32));
  }
}

Finder _bubbleWithText(String text) =>
    find.ancestor(of: find.text(text), matching: find.byType(PendingBubble));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pending queue: queue, reorder, edit, cancel, move, flush', (
    tester,
  ) async {
    await launchMakit(tester);
    await openFirstSession(tester);
    await hold(tester);

    // 1 ── a turn that outlives a keystroke, so there is a busy window at all.
    await sendComposerText(tester, 'SLOW 90000 build the upload route');
    await pumpUntil(tester, find.textContaining('SLOW 90000'));
    await hold(tester);

    // 2 ── two messages typed while the agent works. The server cannot steer a
    // stub, so both queue and appear as ghost bubbles above the composer.
    await sendComposerText(tester, 'also update the README');
    await pumpUntil(tester, _bubbleWithText('also update the README'));
    await hold(tester);

    await sendComposerText(tester, 'and add a test for the 429 path');
    await pumpUntil(tester, _bubbleWithText('and add a test for the 429 path'));
    expect(find.byType(PendingBubble), findsNWidgets(2));
    // The caption is the queue's contract with the user: what goes next.
    expect(find.text('sends next · 1 of 2'), findsOneWidget);
    await hold(tester);

    // 3 ── reorder: push the first one later (queue.reorder on the wire).
    await tester.tap(
      find.descendant(
        of: _bubbleWithText('also update the README'),
        matching: find.byTooltip('Send this later'),
      ),
    );
    await pumpUntil(
      tester,
      find.descendant(
        of: _bubbleWithText('and add a test for the 429 path'),
        matching: find.text('sends next · 1 of 2'),
      ),
    );
    await hold(tester);

    // 4 ── edit in place, with the slash palette inside the editor.
    await tester.tap(find.text('also update the README'));
    // Anchored on "the bubble that has an editor open", not on finder order: the
    // composer's own TextField is mounted too, and `.first` only happens to be
    // the editor because the queue sits above the composer in the tree. Not on
    // the message TEXT either — the first keystroke replaces it.
    final editor = find.descendant(
      of: find.byType(PendingBubble),
      matching: find.byType(TextField),
    );
    await pumpUntil(tester, editor);
    await hold(tester, const Duration(milliseconds: 900));

    await tester.enterText(editor, '/');
    await hold(tester, const Duration(milliseconds: 1200));

    await tester.enterText(editor, 'also update the README and CHANGELOG');
    await hold(tester, const Duration(milliseconds: 700));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await pumpUntil(
      tester,
      _bubbleWithText('also update the README and CHANGELOG'),
    );
    await hold(tester);

    // 5 ── cancel one (queue.cancel): a pending message leaves no transcript
    // trace, because it was never delivered.
    await tester.tap(
      find.descendant(
        of: _bubbleWithText('and add a test for the 429 path'),
        matching: find.byTooltip('Cancel this message'),
      ),
    );
    await pumpUntil(tester, find.text('sends next · 1 of 1'));
    expect(find.byType(PendingBubble), findsNWidgets(1));
    await hold(tester);

    // 6 ── the tray (variant C): the same queue as a compact work list.
    await openSettings(tester);
    await tester.scrollUntilVisible(
      find.text('Compact tray'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await hold(tester, const Duration(milliseconds: 700));
    await tester.tap(find.text('Compact tray'));
    await hold(tester);
    await closeSettings(tester);
    await openSessionContaining(tester, 'upload route');
    await pumpUntil(tester, find.byType(PendingQueueTray));
    expect(find.text('1 message waiting'), findsOneWidget);
    await hold(tester);

    // 7 ── a second message, then reorder inside the tray.
    await sendComposerText(tester, 'and squash the migration');
    await pumpUntil(tester, find.text('2 messages waiting'));
    await hold(tester);
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('and squash the migration'),
          matching: find.byType(TrayRow),
        ),
        matching: find.byTooltip('Send this sooner'),
      ),
    );
    await hold(tester);

    // 8 ── promote: the one action only this branch has. It stops the turn in
    // flight (the SLOW task never finishes) so THIS message goes next, and the
    // other stays queued — where `cancel` would have dropped both.
    await tester.tap(
      find.byTooltip('Stop the current turn and send this now').first,
    );
    await pumpUntil(
      tester,
      find.textContaining('echo: and squash the migration'),
      timeout: const Duration(seconds: 30),
    );
    await hold(tester);
    // The survivor is still pending, and flushes on its own turn.
    await pumpUntil(
      tester,
      find.textContaining('echo: also update the README and CHANGELOG'),
      timeout: const Duration(seconds: 30),
    );
    expect(find.byType(TrayRow), findsNothing, reason: 'queue drained');
    await hold(tester, const Duration(seconds: 2));
  });
}
