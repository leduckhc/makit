import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/transport/media_client.dart';

import 'media_client_test.dart' show kPng;

/// Stands in for the desktop's `POST /media` route (SPEC-user-attachments T1). Records the
/// request so the test can assert the method, content type, and bearer, and can
/// be told to fail with a specific status.
class _FakeUploadServer {
  _FakeUploadServer(this._server, {this.status = 201}) {
    _server.listen((req) async {
      methods.add(req.method);
      paths.add(req.uri.path);
      contentTypes.add(req.headers.contentType?.mimeType);
      authHeaders.add(req.headers.value(HttpHeaders.authorizationHeader));
      bodies.add(
        Uint8List.fromList(
          (await req.fold<List<int>>([], (a, b) => a..addAll(b))),
        ),
      );
      req.response.statusCode = status;
      if (status == 201) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({
            'mediaId': 'a' * 64,
            'mime': 'image/png',
            'sizeBytes': kPng.length,
          }),
        );
      }
      await req.response.close();
    });
  }

  final HttpServer _server;
  final int status;
  final List<String> methods = [];
  final List<String> paths = [];
  final List<String?> contentTypes = [];
  final List<String?> authHeaders = [];
  final List<Uint8List> bodies = [];

  MediaEndpoint get endpoint =>
      MediaEndpoint(base: 'http://127.0.0.1:${_server.port}', bearer: 'tok');
  Future<void> close() => _server.close(force: true);

  static Future<_FakeUploadServer> start({int status = 201}) async =>
      _FakeUploadServer(
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        status: status,
      );
}

void main() {
  test('upload POSTs the bytes to /media and returns the descriptor', () async {
    final srv = await _FakeUploadServer.start();
    addTearDown(srv.close);

    final d = await httpMediaUploader(srv.endpoint)(kPng, 'image/png');

    expect(d.mediaId, 'a' * 64);
    expect(d.mime, 'image/png');
    expect(d.sizeBytes, kPng.length);
    expect(srv.methods.single, 'POST');
    expect(srv.paths.single, '/media');
    expect(srv.contentTypes.single, 'image/png');
    // The bearer must ride in a header, never a query param: the URL ends up in
    // logs and in the replayed event log.
    expect(srv.authHeaders.single, 'Bearer tok');
    expect(srv.bodies.single, kPng);
  });

  test(
    'a 413 surfaces as MediaTooLargeException, so the UI can say why',
    () async {
      final srv = await _FakeUploadServer.start(status: 413);
      addTearDown(srv.close);

      await expectLater(
        httpMediaUploader(srv.endpoint)(kPng, 'image/png'),
        throwsA(isA<MediaTooLargeException>()),
      );
    },
  );

  test(
    'a 415 surfaces as an unsupported-type failure, not a generic error',
    () async {
      final srv = await _FakeUploadServer.start(status: 415);
      addTearDown(srv.close);

      await expectLater(
        httpMediaUploader(srv.endpoint)(kPng, 'image/png'),
        throwsA(isA<MediaUnsupportedTypeException>()),
      );
    },
  );

  test(
    'a 401 surfaces as a fetch failure rather than a silent success',
    () async {
      final srv = await _FakeUploadServer.start(status: 401);
      addTearDown(srv.close);

      await expectLater(
        httpMediaUploader(srv.endpoint)(kPng, 'image/png'),
        throwsA(isA<MediaFetchException>()),
      );
    },
  );

  test(
    'an oversized payload is refused locally, without a round trip',
    () async {
      final srv = await _FakeUploadServer.start();
      addTearDown(srv.close);
      final huge = Uint8List(kMaxAttachmentBytes + 1);

      await expectLater(
        httpMediaUploader(srv.endpoint)(huge, 'image/png'),
        throwsA(isA<MediaTooLargeException>()),
      );
      // No bytes on the wire: uploading 24 MB only to be told 413 wastes the
      // user's mobile data and their time.
      expect(srv.methods, isEmpty);
    },
  );

  test('a mime the server would reject is refused locally too', () async {
    final srv = await _FakeUploadServer.start();
    addTearDown(srv.close);

    await expectLater(
      httpMediaUploader(srv.endpoint)(kPng, 'image/svg+xml'),
      throwsA(isA<MediaUnsupportedTypeException>()),
    );
    expect(srv.methods, isEmpty);
  });

  test('an empty payload is refused locally', () async {
    final srv = await _FakeUploadServer.start();
    addTearDown(srv.close);

    await expectLater(
      httpMediaUploader(srv.endpoint)(Uint8List(0), 'image/png'),
      throwsA(isA<MediaUnsupportedTypeException>()),
    );
    // Locks the local-refusal invariant: a regression that moved this check
    // after the round trip would otherwise still pass here.
    expect(srv.methods, isEmpty);
  });

  test(
    'a malformed 201 body is a failure, not a descriptor with empty fields',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        req.response.statusCode = 201;
        req.response.write('not json');
        await req.response.close();
      });

      await expectLater(
        httpMediaUploader(
          MediaEndpoint(base: 'http://127.0.0.1:${server.port}'),
        )(kPng, 'image/png'),
        throwsA(isA<MediaFetchException>()),
      );
    },
  );

  test('mimeForFilename maps the extensions the picker can hand us', () {
    expect(mimeForFilename('shot.PNG'), 'image/png');
    expect(mimeForFilename('a.jpeg'), 'image/jpeg');
    expect(mimeForFilename('a.jpg'), 'image/jpeg');
    expect(mimeForFilename('a.gif'), 'image/gif');
    expect(mimeForFilename('a.webp'), 'image/webp');
    expect(mimeForFilename('a.bmp'), 'image/bmp');
    // Unsupported or absent → null, so the caller refuses instead of guessing.
    expect(mimeForFilename('notes.pdf'), isNull);
    expect(mimeForFilename('noext'), isNull);
    expect(mimeForFilename('a.svg'), isNull);
  });
}
