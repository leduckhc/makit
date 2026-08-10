import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/notifications/notification_observer.dart';
import 'package:makit/status/status_center.dart';
import 'package:makit/status/status_event.dart';
import 'package:makit/status/status_providers.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';

/// SPEC-48 D7: the notification layer already decides which session changes are
/// worth a person's attention — and then threw that judgement away whenever the
/// app happened to be in the foreground. These pin that every one of them now
/// lands on the record, silently.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final feed = StateProvider<SessionsState>((_) => SessionsState(const []));

  late StatusCenter center;
  late ProviderContainer container;

  setUp(() {
    center = StatusCenter();
    container = ProviderContainer(
      overrides: [
        statusCenterProvider.overrideWithValue(center),
        sessionsProvider.overrideWith((ref) => ref.watch(feed)),
        // The observer labels each event with its project; the real store needs
        // a live connection, which this test has no business standing up.
        projectsProvider.overrideWithValue(
          ProjectsState([Project(id: 'p1', name: 'demo', path: '/tmp/demo')]),
        ),
      ],
    );
    // The UI always watches the session list; without a listener Riverpod never
    // recomputes `sessionsProvider`, so the observer's own `ref.listen` would
    // never fire — pre-existing behaviour of the notification controller, stood
    // in for here so this test exercises the app's actual conditions.
    container.listen<SessionsState>(sessionsProvider, (_, _) {});
    // Reading the controller activates it (as main() does at boot).
    container.read(notificationControllerProvider);
  });

  tearDown(() {
    container.dispose();
    center.dispose();
  });

  // Riverpod delivers listener callbacks on its own scheduler, so a plain
  // `test` has to yield before asserting.
  Future<void> publish(SessionStatus status) async {
    container.read(feed.notifier).state = SessionsState([_session(status)]);
    await Future<void>.delayed(Duration.zero);
  }

  test(
    'a finished turn is recorded as a success against its session',
    () async {
      await publish(SessionStatus.running);
      await publish(SessionStatus.idle);
      final e = center.events.single;
      expect(e.severity, StatusSeverity.success);
      expect(e.title, 'Agent finished its turn.');
      expect(e.sessionId, 's1');
      expect(e.source, StatusSources.agent);
    },
  );

  test('needing you is a warning, an error is a failure', () async {
    await publish(SessionStatus.awaitingInput);
    expect(center.events.first.severity, StatusSeverity.warning);
    await publish(SessionStatus.error);
    expect(center.events.first.severity, StatusSeverity.failure);
  });

  test('the record is silent — no toast, and the badge stays quiet', () async {
    await publish(SessionStatus.awaitingApproval);
    expect(center.events, hasLength(1));
    expect(center.unreadCount, 0);
  });

  test('entering running says nothing at all', () async {
    await publish(SessionStatus.running);
    expect(center.events, isEmpty);
  });

  test('a repeat of the same status says nothing twice', () async {
    await publish(SessionStatus.awaitingInput);
    await publish(SessionStatus.awaitingInput);
    expect(center.events, hasLength(1));
  });
}

Session _session(SessionStatus status) => Session(
  id: 's1',
  projectId: 'p1',
  agent: 'pi',
  title: 'demo',
  status: status,
  policy: ApprovalPolicy.askOnRisky,
);
