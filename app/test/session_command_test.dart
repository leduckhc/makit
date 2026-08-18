// SPEC-session-identity C2b — the `/session` CLIENT command (D7).
//
// This is the entire point of the feature. pi's own `/session` is an AGENT
// command, so typed into makit's composer it falls through to
// `store.sendMessage` and — mid-turn — lands in the server's pending queue,
// executing only after the turn it was meant to help you hand off. Registering
// it in `clientCommands` makes `handleClientCommand` intercept it BEFORE the
// wire, so it works mid-turn.
//
// The single load-bearing assertion is `handleClientCommand('/session')`
// returning TRUE: that one boolean encodes the entire bug report — intercepted,
// never sent.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:makit/status/status_center.dart';
import 'package:makit/status/status_event.dart';
import 'package:makit/status/status_providers.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/composer/client_commands.dart';

const kAgentId = '019fa9f4-443d-7d86-8f4c-d9c4988ddf4f';

Session _session({String? agentSessionId = kAgentId}) => Session(
  id: 's1',
  projectId: 'p1',
  agent: 'pi',
  title: 'Session',
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
  agentSessionId: agentSessionId,
);

/// Records clipboard writes; the platform channel is the only place a bare id
/// copy is observable.
class _Clipboard {
  final List<String> writes = [];

  /// Make the platform channel throw, the way a real clipboard does when another
  /// process holds it (Windows) or the host denies the write.
  bool fail = false;

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          if (fail) {
            throw PlatformException(code: 'copy_failed', message: 'denied');
          }
          writes.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
  }

  void remove(WidgetTester tester) => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null);
}

/// Runs [raw] through `handleClientCommand` inside a real widget tree. Returns
/// the pending future WRAPPED in a record so it is not flattened/awaited here —
/// bare `/session` opens a modal sheet whose future only completes on dismissal,
/// so callers pump, assert, dismiss, then await `.handled` for the boolean.
Future<({Future<bool> handled})> _run(
  WidgetTester tester,
  String raw, {
  required Session session,
  StatusCenter? status,
}) async {
  late Future<bool> pending;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionsProvider.overrideWithValue(SessionsState([session])),
        if (status != null) statusCenterProvider.overrideWithValue(status),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(
              onPressed: () => pending = handleClientCommand(
                raw,
                context: context,
                ref: ref,
                sessionId: session.id,
              ),
              child: const Text('run'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('run'));
  await tester.pump();
  return (handled: pending);
}

/// Dismisses an open modal sheet by tapping its barrier, so a pending
/// `handleClientCommand` future can complete.
Future<void> _dismissSheet(WidgetTester tester) async {
  await tester.tapAt(const Offset(10, 10));
  await tester.pumpAndSettle();
}

void main() {
  late _Clipboard clipboard;
  setUp(() => clipboard = _Clipboard());

  testWidgets('bare /session is intercepted (never sent to the agent)', (
    tester,
  ) async {
    // THE bug report, as one assertion: a `true` return means the send path
    // does not reach `store.sendMessage`, so `/session` no longer queues behind
    // the running turn.
    final r = await _run(tester, '/session', session: _session());
    await _dismissSheet(tester);
    expect(await r.handled, isTrue);
  });

  testWidgets('bare /session opens the panel and does NOT copy', (
    tester,
  ) async {
    clipboard.install(tester);
    addTearDown(() => clipboard.remove(tester));
    await _run(tester, '/session', session: _session());
    expect(find.text(kAgentId), findsOneWidget); // panel is showing the id
    expect(clipboard.writes, isEmpty); // copying is /session id's job (D6)
    await _dismissSheet(tester);
  });

  testWidgets('/session id copies EXACTLY the bare id and nothing else', (
    tester,
  ) async {
    clipboard.install(tester);
    addTearDown(() => clipboard.remove(tester));
    final status = StatusCenter();
    addTearDown(status.dispose);
    final r = await _run(
      tester,
      '/session id',
      session: _session(),
      status: status,
    );
    expect(await r.handled, isTrue);
    expect(clipboard.writes, [kAgentId]); // the bare id, not the whole payload
    expect(status.events.map((e) => e.title), contains('Session id copied'));
  });

  testWidgets('/session id with no agent id copies nothing and says why', (
    tester,
  ) async {
    clipboard.install(tester);
    addTearDown(() => clipboard.remove(tester));
    final status = StatusCenter();
    addTearDown(status.dispose);
    await _run(
      tester,
      '/session id',
      session: _session(agentSessionId: null),
      status: status,
    );
    expect(clipboard.writes, isEmpty);
    expect(
      status.events.map((e) => e.title),
      contains('No agent session id yet'),
    );
  });

  testWidgets('/session id reports a clipboard failure instead of throwing', (
    tester,
  ) async {
    // A `Clipboard.setData` that throws (another process holds the clipboard on
    // Windows; the host denies the write) must not escape the handler: the user
    // would then get neither the id nor any word about why. Asserted against the
    // STATUS BUS, because the test host has no toast overlay — a rendered-text
    // assertion here could never fail.
    clipboard
      ..install(tester)
      ..fail = true;
    addTearDown(() => clipboard.remove(tester));
    final status = StatusCenter();
    addTearDown(status.dispose);
    final r = await _run(
      tester,
      '/session id',
      session: _session(),
      status: status,
    );
    expect(await r.handled, isTrue);
    expect(
      tester.takeException(),
      isNull,
      reason: 'the PlatformException must not escape the handler',
    );
    expect(clipboard.writes, isEmpty);
    expect(
      status.events.map((e) => e.title),
      isNot(contains('Session id copied')),
      reason: 'a failed write must never claim success',
    );
    final failed = status.events.where(
      (e) => e.title == 'Could not copy session id',
    );
    expect(failed, hasLength(1));
    expect(
      failed.single.severity,
      StatusSeverity.failure,
      reason: 'an action the user asked for did not happen',
    );
  });

  testWidgets('/sessions (a different word) is NOT intercepted', (
    tester,
  ) async {
    // Matching is exact, not prefix-based: `/sessions` must fall through to the
    // agent. The "make the matcher prefix-based" mutation flips this to true.
    final r = await _run(tester, '/sessions', session: _session());
    expect(await r.handled, isFalse);
  });
}
