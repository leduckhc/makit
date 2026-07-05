// SPEC-05: Session DTO carries optional pane info; codec parses it.
import 'package:flutter_test/flutter_test.dart';
import 'package:pino/store/models.dart';
import 'package:pino/transport/codec.dart';

void main() {
  group('Session pane field', () {
    test('decodeSessions parses pane info when present', () {
      final sessions = WireCodec.decodeSessions([
        {
          'id': 's1',
          'projectId': 'p1',
          'agent': 'pi',
          'title': 'my session',
          'status': 'idle',
          'policy': 'ask-on-risky',
          'lastActivityAt': 0,
          'lastPreview': '',
          'pane': {'mux': 'herdr', 'paneId': 'w1:p3'},
        },
      ]);
      expect(sessions, isNotNull);
      expect(sessions!.length, 1);
      final pane = sessions.first.pane;
      expect(pane, isNotNull);
      expect(pane!.mux, 'herdr');
      expect(pane.paneId, 'w1:p3');
    });

    test('decodeSessions works without pane field (backwards compat)', () {
      final sessions = WireCodec.decodeSessions([
        {
          'id': 's2',
          'projectId': 'p1',
          'agent': 'pi',
          'title': 'headless',
          'status': 'idle',
          'policy': 'ask-on-risky',
          'lastActivityAt': 0,
          'lastPreview': '',
        },
      ]);
      expect(sessions, isNotNull);
      expect(sessions!.first.pane, isNull);
    });

    test('Session.copyWith preserves pane', () {
      const pane = PaneInfo(mux: 'herdr', paneId: 'w1:p1');
      final s = Session(
        id: 's1',
        projectId: 'p1',
        agent: 'pi',
        title: 'orig',
        status: SessionStatus.idle,
        policy: ApprovalPolicy.askOnRisky,
        pane: pane,
      );
      final updated = s.copyWith(title: 'updated');
      expect(updated.pane, pane);
    });

    test('Session.copyWith can clear pane', () {
      const pane = PaneInfo(mux: 'herdr', paneId: 'w1:p1');
      final s = Session(
        id: 's1',
        projectId: 'p1',
        agent: 'pi',
        title: 'orig',
        status: SessionStatus.idle,
        policy: ApprovalPolicy.askOnRisky,
        pane: pane,
      );
      final updated = s.copyWith(clearPane: true);
      expect(updated.pane, isNull);
    });
  });
}
