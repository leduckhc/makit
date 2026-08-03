import 'package:flutter_test/flutter_test.dart';
import 'package:makit/transport/codec.dart';
import 'package:makit/transport/protocol.dart';

/// A representative full `metrics.sample` payload (the object under `sample`).
Map<String, dynamic> _fullSample() => {
  'ts': 1785500000000,
  'app': <String, dynamic>{
    'pid': 4242,
    'rssBytes': 188743680,
    'cpuPercent': 2.4,
    'cpuSeconds': 12.4,
  },
  'server': <String, dynamic>{
    'pid': 4201,
    'rssBytes': 100663296,
    'cpuPercent': 0.9,
    'cpuSeconds': 5.1,
    'eventLoop': {'p50': 1.2, 'p99': 3.4},
  },
  'agents': [
    <String, dynamic>{
      'pid': 5001,
      'rssBytes': 230686720,
      'cpuPercent': 6.5,
      'cpuSeconds': 44.2,
      'sessionId': 's-codex-1',
      'label': 'codex · wire up pairing',
      'inTurn': true,
      'procs': 3,
      'uptimeMs': 61000,
    },
  ],
  'wire': {'inBytesPerSec': 1400, 'outBytesPerSec': 3200, 'framesPerSec': 2},
  'storage': {'eventLogBytes': 2097152},
  'sampler': <String, dynamic>{'cpuPercent': 0.3, 'rssBytes': 4194304},
  'turnActive': true,
  'procTableOk': true,
};

Envelope _frame(Map<String, dynamic> sample, {Object? history}) => Envelope(
  t: MsgType.event,
  id: 'e1',
  body: {'kind': 'metrics.sample', 'sample': sample, 'history': ?history},
);

void main() {
  group('WireCodec metrics.sample', () {
    test('decodes a full frame into a typed sample', () {
      final decoded = WireCodec.decode(_frame(_fullSample()));
      expect(decoded, isA<MetricsSampleFrame>());
      final s = (decoded as MetricsSampleFrame).sample;

      expect(s.ts, 1785500000000);
      expect(s.app, isNotNull);
      expect(s.app!.pid, 4242);
      expect(s.app!.cpuPercent, 2.4);
      expect(s.server.pid, 4201);
      expect(s.server.eventLoopP50, 1.2);
      expect(s.server.eventLoopP99, 3.4);
      expect(s.agents, hasLength(1));
      expect(s.agents.first.sessionId, 's-codex-1');
      expect(s.agents.first.procs, 3);
      expect(s.agents.first.uptimeMs, 61000);
      expect(s.wire.outBytesPerSec, 3200);
      expect(s.storage, isNotNull);
      expect(s.storage!.eventLogBytes, 2097152);
      expect(s.sampler.cpuPercent, 0.3);
      expect(s.turnActive, isTrue);
      expect(s.procTableOk, isTrue);
      expect(decoded.history, isNull);
    });

    test('history array decodes into a list of samples', () {
      final decoded =
          WireCodec.decode(_frame(_fullSample(), history: [_fullSample()]))
              as MetricsSampleFrame;
      expect(decoded.history, hasLength(1));
      expect(decoded.history!.first.ts, 1785500000000);
    });

    test('app: null ⇒ app is null (phone / unmeasured)', () {
      final s =
          (WireCodec.decode(_frame({..._fullSample(), 'app': null}))
                  as MetricsSampleFrame)
              .sample;
      expect(s.app, isNull);
    });

    test('storage: null ⇒ storage is null (coarse tick)', () {
      final s =
          (WireCodec.decode(_frame({..._fullSample(), 'storage': null}))
                  as MetricsSampleFrame)
              .sample;
      expect(s.storage, isNull);
    });

    test(
      'cpuPercent: null survives as null — never coerced to 0 (decision 2)',
      () {
        final j = _fullSample();
        (j['app'] as Map)['cpuPercent'] = null;
        (j['server'] as Map)['cpuPercent'] = null;
        (j['sampler'] as Map)['cpuPercent'] = null;
        ((j['agents'] as List).first as Map)['cpuPercent'] = null;
        final s = (WireCodec.decode(_frame(j)) as MetricsSampleFrame).sample;
        expect(s.app!.cpuPercent, isNull);
        expect(s.server.cpuPercent, isNull);
        expect(s.sampler.cpuPercent, isNull);
        expect(s.agents.first.cpuPercent, isNull);
      },
    );

    test('agents absent ⇒ empty list', () {
      final j = _fullSample()..remove('agents');
      final s = (WireCodec.decode(_frame(j)) as MetricsSampleFrame).sample;
      expect(s.agents, isEmpty);
    });

    test('procs/uptimeMs absent (coarse frame) ⇒ null, not 0', () {
      final j = _fullSample();
      ((j['agents'] as List).first as Map)
        ..remove('procs')
        ..remove('uptimeMs');
      final s = (WireCodec.decode(_frame(j)) as MetricsSampleFrame).sample;
      expect(s.agents.first.procs, isNull);
      expect(s.agents.first.uptimeMs, isNull);
    });

    test('procTableOk: false decodes and is visible (decision 13)', () {
      final j = {
        ..._fullSample(),
        'procTableOk': false,
        'app': null,
        'agents': <Object?>[],
      };
      final s = (WireCodec.decode(_frame(j)) as MetricsSampleFrame).sample;
      expect(s.procTableOk, isFalse);
      expect(s.app, isNull);
      expect(s.agents, isEmpty);
    });

    test('garbage ts ⇒ _warn + skip (null), does not throw', () {
      final decoded = WireCodec.decode(
        _frame({..._fullSample(), 'ts': 'nope'}),
      );
      expect(decoded, isNull);
    });

    test('garbage server ⇒ _warn + skip (null), does not throw', () {
      final decoded = WireCodec.decode(
        _frame({..._fullSample(), 'server': 'nope'}),
      );
      expect(decoded, isNull);
    });

    test('non-map sample ⇒ null, does not throw', () {
      final env = Envelope(
        t: MsgType.event,
        id: 'e1',
        body: {'kind': 'metrics.sample', 'sample': 'garbage'},
      );
      expect(WireCodec.decode(env), isNull);
    });
  });
}
