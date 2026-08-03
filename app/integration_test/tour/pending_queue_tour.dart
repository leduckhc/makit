// A driven walkthrough of the pending-message queue (SPEC-35/36), for screen
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
//   6. switch the placement setting to "In the transcript" and see it move
//   7. let the turn finish and watch the survivor flush into a real message
//
// Each step holds still for a beat so the recording is watchable, and asserts
// just enough that a broken step fails the run instead of filming a blank
// screen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:makit/ui/composer/pending_queue.dart';

import '../e2e_helpers.dart';

/// How long each step lingers so the camera catches it.
const _beat = Duration(milliseconds: 1600);

/// Real (wall-clock) settle: `pumpAndSettle` fast-forwards time in a way that
/// makes the recording jump, so the tour pumps frames for a real duration.
Future<void> hold(WidgetTester tester, [Duration d = _beat]) async {
  final deadline = DateTime.now().add(d);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 32));
  }
}

Finder _bubbleWithText(String text) => find.ancestor(
  of: find.text(text),
  matching: find.byType(PendingBubble),
);

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
    await pumpUntil(tester, find.byType(TextField).at(0));
    await hold(tester, const Duration(milliseconds: 900));

    await tester.enterText(find.byType(TextField).first, '/');
    await hold(tester, const Duration(milliseconds: 1200));

    await tester.enterText(
      find.byType(TextField).first,
      'also update the README and CHANGELOG',
    );
    await hold(tester, const Duration(milliseconds: 700));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await pumpUntil(tester, _bubbleWithText('also update the README and CHANGELOG'));
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

    // 6 ── the placement preference: the same queue, in the transcript instead.
    await openSettings(tester);
    // The Chat section is below the fold on a phone: scroll it into view, or the
    // tap lands off-screen and is silently swallowed (only a warning).
    await tester.scrollUntilVisible(
      find.text('In the transcript'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await hold(tester, const Duration(milliseconds: 900));
    await tester.tap(find.text('In the transcript'));
    await hold(tester);
    await closeSettings(tester);
    await openSessionContaining(tester, 'upload route');
    await pumpUntil(tester, _bubbleWithText('also update the README and CHANGELOG'));
    await hold(tester);

    // 7 ── the turn ends and the survivor flushes: ghost becomes a real message.
    await pumpUntil(
      tester,
      find.textContaining('done after'),
      timeout: const Duration(seconds: 120),
    );
    await pumpUntil(
      tester,
      find.textContaining('echo: also update the README and CHANGELOG'),
      timeout: const Duration(seconds: 30),
    );
    expect(find.byType(PendingBubble), findsNothing, reason: 'queue drained');
    await hold(tester, const Duration(seconds: 2));
  });
}
