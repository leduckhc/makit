// A driven walkthrough of the pending-message queue (SPEC-35/36) on the **macOS**
// desktop surface, for screen capture.
//
// Not an assertion suite — a *camera path*, like `pending_queue_tour.dart` (its
// iOS counterpart). Both run against the real WSS server with the StubAdapter,
// so what the camera sees is the real wire: `send.message`, `queue.update`,
// `queue.reorder`, `queue.cancel`.
//
// It mounts the genuine `DesktopChatPane` on a genuine store — no provider
// overrides, no fake sessions — because the point is to film the shipping
// widget, not a stand-in. The session id is read off the live store once the
// snapshot arrives.
//
// Camera path:
//   1. start a long turn (`SLOW`) so the agent is busy and a queue can exist
//   2. type two more messages — they queue as ghost bubbles above the composer
//   3. reorder them
//   4. edit one in place, and open the slash palette inside the editor
//   5. cancel one
//   6. let the turn finish and watch the survivor flush into a real message
//
// The placement preference (pinned vs inline) is deliberately NOT filmed here:
// on desktop it lives in Settings › Agents & Chat, a different screen, and the
// iOS tour already shows the switch. Filming it would mean composing the chat
// pane and a settings section into one synthetic window, which is not a thing
// any user sees.
//
// Run under `tool/record-queue-tour-desktop.sh`, which films the screen with
// cua-driver (its own Screen Recording grant) while this drives.
//
// ignore_for_file: depend_on_referenced_packages
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:makit/app/test_bootstrap.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/desktop/chat/desktop_chat_shell.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/composer/pending_queue.dart';

/// How long each step lingers so the camera catches it.
const _beat = Duration(milliseconds: 1600);

/// Real (wall-clock) settle: `pumpAndSettle` fast-forwards time in a way that
/// makes the recording jump — and never settles at all while the working
/// indicator animates — so the tour pumps frames for a real duration instead.
Future<void> hold(WidgetTester tester, [Duration d = _beat]) async {
  final deadline = DateTime.now().add(d);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 32));
  }
}

Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 20),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) {
      await tester.pump(const Duration(milliseconds: 100));
      return;
    }
  }
  fail(reason ?? 'timed out waiting for $finder');
}

Finder _bubbleWithText(String text) =>
    find.ancestor(of: find.text(text), matching: find.byType(PendingBubble));

/// Type into the composer and send. Tapping first is not optional: `_send()`
/// unfocuses the field, so a second `enterText` against it silently types
/// nothing under the live binding.
Future<void> send(WidgetTester tester, String text) async {
  final field = find.byType(TextField).last;
  await pumpUntil(tester, find.byType(TextField), reason: 'no composer');
  await tester.tap(field);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.enterText(field, text);
  // `hold`, not a single 300ms `pump`: the send slot's AnimatedSwitcher throws
  // `Duplicate keys found` when asked to return to a key still animating out
  // (pre-existing on main — reproducible with no queue and no desktop), and one
  // fat frame advances the controller without ever rendering the frame that
  // retires the outgoing child. Real frames let each crossfade actually finish.
  await hold(tester, const Duration(milliseconds: 400));
  await tester.tap(find.byKey(const ValueKey('send')));
  await hold(tester, const Duration(milliseconds: 400));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('desktop pending queue: queue, reorder, edit, cancel, flush', (
    tester,
  ) async {
    // Same handshake the mobile client uses: the harness seeds paired creds
    // (host/port/bearer/cert fingerprint) and the store connects on first read.
    // cua-driver reads the accessibility tree to find and front this window,
    // which turns Flutter's semantics ON mid-test — and the test then fails at
    // teardown with "A SemanticsHandle was active at the end of the test" even
    // though the camera path completed. Owning a handle here means the tour
    // disposes it, instead of the harness noticing a stray one.
    final semantics = tester.ensureSemantics();
    addTearDown(semantics.dispose);

    await seedTestPairingIfRequested();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(storeControllerProvider);

    // The REAL shell, not a hand-composed pane: it supplies the sidebar, the
    // pane tree and the constraints the chat pane is written against. A bare
    // `Scaffold(body: DesktopChatPane(...))` is a layout no user ever sees (and
    // overflows by ~40k px).
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: makitLightTheme,
          home: const DesktopChatShell(),
        ),
      ),
    );

    // Wait for the sessions snapshot, then open the seeded session the way a
    // user does: click its row in the sidebar.
    await pumpUntil(
      tester,
      find.textContaining('new session'),
      timeout: const Duration(seconds: 30),
      reason: 'no session row arrived from the server',
    );
    await tester.tap(find.textContaining('new session').first);
    await pumpUntil(tester, find.byType(TextField), reason: 'no composer');
    await hold(tester);

    // 1 ── a turn that outlives a keystroke, so there is a busy window at all.
    await send(tester, 'SLOW 90000 build the upload route');
    await pumpUntil(tester, find.textContaining('SLOW 90000'));
    await hold(tester);

    // 2 ── two messages typed while the agent works. pi/ACP has no steer
    // primitive and the stub has none either, so both queue.
    await send(tester, 'also update the README');
    await pumpUntil(tester, _bubbleWithText('also update the README'));
    await hold(tester);

    await send(tester, 'and add a test for the 429 path');
    await pumpUntil(tester, _bubbleWithText('and add a test for the 429 path'));
    expect(find.byType(PendingBubble), findsNWidgets(2));
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
    // Anchored on "the bubble that has an editor open", NOT on the message's
    // text: `_bubbleWithText` matches a Text/EditableText carrying that string,
    // and the first keystroke replaces it — so a text-anchored finder matches
    // zero widgets exactly when the tour needs it, and `enterText` throws
    // `Bad state: No element`. Only one editor is ever open at a time.
    final editorField = find.descendant(
      of: find.byType(PendingBubble),
      matching: find.byType(TextField),
    );
    await pumpUntil(tester, editorField);
    await hold(tester, const Duration(milliseconds: 900));

    await tester.enterText(editorField, '/');
    await hold(tester, const Duration(milliseconds: 1200));

    await tester.enterText(editorField, 'also update the README and CHANGELOG');
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

    // 6 ── the turn ends and the survivor flushes: ghost becomes a real message.
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
