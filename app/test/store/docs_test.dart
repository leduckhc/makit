import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/docs.dart';
import 'package:makit/store/store.dart';
import 'package:makit/transport/codec.dart';
import 'package:makit/transport/protocol.dart';

/// A minimal valid doc map, so each test only overrides the field it probes.
Map<String, dynamic> _docJson({
  String key = '/repo:mockups/a.html',
  String relPath = 'mockups/a.html',
  String title = 'Board A',
  String kind = 'html',
  Object? bytes = 42000,
  Object? modifiedAt = 3000,
  String worktreePath = '/repo',
  Object? sessionId,
  Object? changed,
  Object? docStatus,
}) => {
  'key': key,
  'relPath': relPath,
  'title': title,
  'kind': kind,
  'bytes': bytes,
  'modifiedAt': modifiedAt,
  'worktreePath': worktreePath,
  'sessionId': ?sessionId,
  'changed': ?changed,
  'docStatus': ?docStatus,
};

void main() {
  group('DocInfo.fromJson tolerance', () {
    test('a valid map decodes every field', () {
      final d = DocInfo.fromJson(
        _docJson(
          kind: 'md',
          sessionId: 's-1',
          changed: true,
          docStatus: 'Draft',
        ),
      );
      expect(d, isNotNull);
      expect(d!.key, '/repo:mockups/a.html');
      expect(d.relPath, 'mockups/a.html');
      expect(d.title, 'Board A');
      expect(d.kind, DocKind.md);
      expect(d.bytes, 42000);
      expect(d.modifiedAt, 3000);
      expect(d.worktreePath, '/repo');
      expect(d.sessionId, 's-1');
      expect(d.changed, isTrue);
      expect(d.docStatus, 'Draft');
    });

    test('an unknown kind drops the whole entry (never coerced)', () {
      expect(DocInfo.fromJson(_docJson(kind: 'pdf')), isNull);
    });

    test('a non-numeric bytes/modifiedAt drops the entry', () {
      expect(DocInfo.fromJson(_docJson(bytes: 'oops')), isNull);
      expect(DocInfo.fromJson(_docJson(modifiedAt: 'oops')), isNull);
    });

    test('a missing required string drops the entry', () {
      final j = _docJson()..remove('title');
      expect(DocInfo.fromJson(j), isNull);
    });

    test('absent changed stays null — never coerced to false', () {
      final d = DocInfo.fromJson(_docJson())!;
      expect(d.changed, isNull);
      expect(d.changed, isNot(false));
    });

    test('absent docStatus stays null — never coerced to ""', () {
      final d = DocInfo.fromJson(_docJson())!;
      expect(d.docStatus, isNull);
      expect(d.docStatus, isNot(''));
    });

    test('absent sessionId stays null', () {
      final d = DocInfo.fromJson(_docJson())!;
      expect(d.sessionId, isNull);
    });

    test('a non-bool changed is dropped to null, not coerced', () {
      final d = DocInfo.fromJson(_docJson(changed: 'yes'))!;
      expect(d.changed, isNull);
    });

    test('a non-string docStatus is dropped to null', () {
      final d = DocInfo.fromJson(_docJson(docStatus: 7))!;
      expect(d.docStatus, isNull);
    });
  });

  group('DocsSnapshot.fromJson', () {
    test('drops malformed entries but keeps the rest', () {
      final snap = DocsSnapshot.fromJson({
        'docs': [
          _docJson(),
          _docJson(kind: 'pdf'), // dropped
          _docJson(relPath: 'docs/b.md', kind: 'md'),
        ],
        'scannedAt': 5000,
        'scanOk': true,
      });
      expect(snap, isNotNull);
      expect(snap!.docs, hasLength(2));
      expect(snap.scanOk, isTrue);
      expect(snap.scannedAt, 5000);
    });

    test('a missing docs list or scanOk drops the whole snapshot', () {
      expect(DocsSnapshot.fromJson({'scannedAt': 1, 'scanOk': true}), isNull);
      expect(
        DocsSnapshot.fromJson({'docs': const <Object>[], 'scannedAt': 1}),
        isNull,
      );
    });

    test('carries scanError when present', () {
      final snap = DocsSnapshot.fromJson({
        'docs': const <Object>[],
        'scannedAt': 1,
        'scanOk': false,
        'scanError': 'walk denied',
      })!;
      expect(snap.scanError, 'walk denied');
    });
  });

  group('DocGrant.fromJson', () {
    test('decodes a tailnet grant', () {
      final g = DocGrant.fromJson({
        'grantId': '7f3a',
        'worktreePath': '/repo',
        'relPath': 'mockups/a.html',
        'url': 'https://mac.ts.net/docs/7f3a/mockups/a.html',
        'reach': 'tailnet',
        'expiresAt': 9000,
      });
      expect(g, isNotNull);
      expect(g!.reach, DocReach.tailnet);
      expect(g.url, 'https://mac.ts.net/docs/7f3a/mockups/a.html');
      expect(g.grantId, '7f3a');
    });

    test('an unknown reach drops the grant (never a fabricated URL)', () {
      expect(
        DocGrant.fromJson({
          'grantId': '7f3a',
          'worktreePath': '/repo',
          'relPath': 'mockups/a.html',
          'url': 'https://x/y',
          'reach': 'carrier-pigeon',
          'expiresAt': 9000,
        }),
        isNull,
      );
    });
  });

  group('DocsWatch ref-counting', () {
    test('sends on:true only on 0→1 and on:false only on 1→0', () {
      final calls = <bool>[];
      final watch = DocsWatch(calls.add);
      watch.watch();
      watch.watch();
      expect(calls, [true]);
      watch.release();
      expect(calls, [true]);
      watch.release();
      expect(calls, [true, false]);
    });

    test('release with no watchers is a no-op', () {
      final calls = <bool>[];
      DocsWatch(calls.add).release();
      expect(calls, isEmpty);
    });
  });

  group('codec + store wiring', () {
    test('a docs.snapshot event decodes and reduces into the store', () {
      final env = Envelope(
        t: MsgType.event,
        id: 'e1',
        body: {
          'kind': 'docs.snapshot',
          'snapshot': {
            'docs': [_docJson(relPath: 'docs/a.md', kind: 'md')],
            'scannedAt': 7000,
            'scanOk': true,
          },
        },
      );
      final decoded = WireCodec.decode(env);
      expect(decoded, isA<DocsSnapshotFrame>());
      final next = reduce(StoreState.empty(), decoded!);
      expect(next.docs, isNotNull);
      expect(next.docs!.docs.single.relPath, 'docs/a.md');
    });

    test(
      'a malformed docs.snapshot payload drops the frame (never throws)',
      () {
        final env = Envelope(
          t: MsgType.event,
          id: 'e2',
          body: {'kind': 'docs.snapshot', 'snapshot': 'not-a-map'},
        );
        expect(WireCodec.decode(env), isNull);
      },
    );
  });
}
