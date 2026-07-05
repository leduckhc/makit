// Test file colocated under lib/ per SPEC-03 Stream A layout; flutter_test is a
// dev dependency, which is expected here.
// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pino/control/control_codec.dart';
import 'package:pino/control/control_types.dart';
import 'package:pino/store/models.dart';

void main() {
  group('encodeRequest', () {
    test('omits args when none given and ends with a newline', () {
      final line = encodeRequest(ControlVerb.status, id: 'c1');
      expect(line.endsWith('\n'), isTrue);
      final decoded = jsonDecode(line) as Map<String, dynamic>;
      expect(decoded, {'id': 'c1', 'verb': 'status'});
      expect(decoded.containsKey('args'), isFalse);
    });

    test('includes args when provided', () {
      final line = encodeRequest(
        ControlVerb.logsTail,
        id: 'c2',
        args: {'lines': 10, 'follow': true},
      );
      final decoded = jsonDecode(line) as Map<String, dynamic>;
      expect(decoded, {
        'id': 'c2',
        'verb': 'logs.tail',
        'args': {'lines': 10, 'follow': true},
      });
    });

    test('maps every verb to its frozen wire name', () {
      expect(ControlVerb.status.wire, 'status');
      expect(ControlVerb.pairMint.wire, 'pair.mint');
      expect(ControlVerb.pairCurrent.wire, 'pair.current');
      expect(ControlVerb.devicesList.wire, 'devices.list');
      expect(ControlVerb.devicesRevoke.wire, 'devices.revoke');
      expect(ControlVerb.sessionsList.wire, 'sessions.list');
      expect(ControlVerb.serverStop.wire, 'server.stop');
      expect(ControlVerb.logsTail.wire, 'logs.tail');
    });
  });

  group('decodeResponse', () {
    test('parses an ok response with raw data', () {
      final res = decodeResponse('{"id":"c1","ok":true,"data":{"pid":42}}');
      expect(res, isA<ControlOk<dynamic>>());
      final ok = res! as ControlOk<dynamic>;
      expect(ok.id, 'c1');
      expect(ok.data, {'pid': 42});
    });

    test('parses an ok response without data', () {
      final res = decodeResponse('{"id":"c1","ok":true}');
      expect(res, isA<ControlOk<dynamic>>());
      expect((res! as ControlOk<dynamic>).data, isNull);
    });

    test('parses an error response', () {
      final res = decodeResponse('{"id":"c1","ok":false,"error":"boom"}');
      expect(res, isA<ControlErr<dynamic>>());
      final err = res! as ControlErr<dynamic>;
      expect(err.id, 'c1');
      expect(err.error, 'boom');
    });

    test('returns null on malformed json', () {
      expect(decodeResponse('not json'), isNull);
      expect(decodeResponse('{"id":'), isNull);
    });

    test('returns null when id is missing or not a string', () {
      expect(decodeResponse('{"ok":true}'), isNull);
      expect(decodeResponse('{"id":1,"ok":true}'), isNull);
    });

    test('returns null when ok is not a bool', () {
      expect(decodeResponse('{"id":"c1","ok":"yes"}'), isNull);
    });

    test('returns null when an error response has no string error', () {
      expect(decodeResponse('{"id":"c1","ok":false}'), isNull);
      expect(decodeResponse('{"id":"c1","ok":false,"error":1}'), isNull);
    });

    test('returns null for a non-object top-level value', () {
      expect(decodeResponse('[1,2,3]'), isNull);
      expect(decodeResponse('42'), isNull);
    });
  });

  group('parseVerbData', () {
    test('status', () {
      final data = parseVerbData(ControlVerb.status, {
        'pid': 42,
        'uptimeMs': 1000,
        'host': '127.0.0.1',
        'port': 8080,
        'fingerprint': 'ab:cd',
        'advertiseHost': 'mac.local',
        'pairedDevices': 2,
        'runningSessions': 1,
        'version': '0.1.0',
      });
      expect(data, isA<StatusData>());
      final s = data! as StatusData;
      expect(s.pid, 42);
      expect(s.uptimeMs, 1000);
      expect(s.host, '127.0.0.1');
      expect(s.port, 8080);
      expect(s.fingerprint, 'ab:cd');
      expect(s.advertiseHost, 'mac.local');
      expect(s.pairedDevices, 2);
      expect(s.runningSessions, 1);
      expect(s.version, '0.1.0');
    });

    test('status returns null on bad shape', () {
      expect(parseVerbData(ControlVerb.status, {'pid': 'nope'}), isNull);
      expect(parseVerbData(ControlVerb.status, 'nope'), isNull);
    });

    test('pair.mint', () {
      final data = parseVerbData(ControlVerb.pairMint, {
        'url': 'pino://x',
        'token': 'tok',
        'expiresAt': 123,
        'fingerprint': 'ab:cd',
      });
      expect(data, isA<PairMintData>());
      final m = data! as PairMintData;
      expect(m.url, 'pino://x');
      expect(m.token, 'tok');
      expect(m.expiresAt, 123);
      expect(m.fingerprint, 'ab:cd');
    });

    test('pair.current with a token', () {
      final data = parseVerbData(ControlVerb.pairCurrent, {
        'url': 'pino://x',
        'token': 'tok',
        'expiresAt': 123,
      });
      expect(data, isA<PairCurrentData>());
      final c = data! as PairCurrentData;
      expect(c.url, 'pino://x');
      expect(c.token, 'tok');
      expect(c.expiresAt, 123);
    });

    test('pair.current returns null when there is no active token', () {
      expect(parseVerbData(ControlVerb.pairCurrent, null), isNull);
    });

    test('devices.list', () {
      final data = parseVerbData(ControlVerb.devicesList, {
        'devices': [
          {
            'id': 'd1',
            'label': 'iPhone',
            'pairedAt': 1,
            'lastSeenAt': 2,
            'connected': true,
          },
        ],
      });
      expect(data, isA<DevicesListData>());
      final d = data! as DevicesListData;
      expect(d.devices.length, 1);
      expect(d.devices.single.id, 'd1');
      expect(d.devices.single.label, 'iPhone');
      expect(d.devices.single.pairedAt, 1);
      expect(d.devices.single.lastSeenAt, 2);
      expect(d.devices.single.connected, isTrue);
    });

    test('devices.list drops malformed device entries', () {
      final data =
          parseVerbData(ControlVerb.devicesList, {
                'devices': [
                  {'id': 'd1', 'label': 'ok', 'pairedAt': 1, 'lastSeenAt': 2, 'connected': true},
                  {'id': 42},
                ],
              })!
              as DevicesListData;
      expect(data.devices.length, 1);
    });

    test('devices.revoke', () {
      final data =
          parseVerbData(ControlVerb.devicesRevoke, {'removed': true})!
              as DevicesRevokeData;
      expect(data.removed, isTrue);
    });

    test('sessions.list', () {
      final data =
          parseVerbData(ControlVerb.sessionsList, {
                'sessions': [
                  {
                    'id': 's1',
                    'projectId': 'p1',
                    'agent': 'pi',
                    'title': 'work',
                    'status': 'running',
                    'policy': 'ask-on-risky',
                    'lastActivityAt': 99,
                    'lastPreview': 'hi',
                  },
                ],
              })!
              as SessionsListData;
      expect(data.sessions.length, 1);
      final s = data.sessions.single;
      expect(s.id, 's1');
      expect(s.projectId, 'p1');
      expect(s.agent, 'pi');
      expect(s.title, 'work');
      expect(s.status, SessionStatus.running);
      expect(s.policy, ApprovalPolicy.askOnRisky);
      expect(s.lastActivityAt, 99);
      expect(s.lastPreview, 'hi');
      expect(s.pane, isNull);
    });

    test('sessions.list parses an optional pane', () {
      final data =
          parseVerbData(ControlVerb.sessionsList, {
                'sessions': [
                  {
                    'id': 's1',
                    'projectId': 'p1',
                    'agent': 'pi',
                    'title': 'work',
                    'status': 'running',
                    'policy': 'yolo',
                    'lastActivityAt': 0,
                    'lastPreview': '',
                    'pane': {'mux': 'tmux', 'paneId': '%1'},
                  },
                ],
              })!
              as SessionsListData;
      expect(data.sessions.single.pane, const PaneInfo(mux: 'tmux', paneId: '%1'));
    });

    test('server.stop', () {
      final data =
          parseVerbData(ControlVerb.serverStop, {'stopping': true})!
              as ServerStopData;
      expect(data.stopping, isTrue);
    });

    test('logs.tail line chunk', () {
      final chunk =
          parseVerbData(ControlVerb.logsTail, {'line': 'hello'})! as LogLine;
      expect(chunk.line, 'hello');
    });

    test('logs.tail done chunk', () {
      final chunk =
          parseVerbData(ControlVerb.logsTail, {'done': true})!;
      expect(chunk, isA<LogDone>());
    });

    test('logs.tail returns null for an unrecognized chunk', () {
      expect(parseVerbData(ControlVerb.logsTail, {'nope': 1}), isNull);
    });
  });
}
