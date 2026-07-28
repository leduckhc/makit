import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/transport/media_client.dart';

/// Ids the fake route treats as a GC'd blob / an unauthorized fetch. Real
/// sha256 hex, because [MediaEndpoint.urlFor] validates the id shape.
const kGoneId = 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
const kDeniedId = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';

/// A 1×1 PNG — small enough to inline, real enough to decode.
final Uint8List kPng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// Stands in for the desktop's `/media` route. Records what it was asked for so
/// the test can assert on the path and the Authorization header.
class _FakeMediaServer {
  _FakeMediaServer(this._server) {
    _server.listen((req) async {
      paths.add(req.uri.path);
      authHeaders.add(req.headers.value(HttpHeaders.authorizationHeader));
      final id = req.uri.pathSegments.last;
      if (id == kGoneId) {
        req.response.statusCode = 404;
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"error":"media_not_found"}');
      } else if (id == kDeniedId) {
        req.response.statusCode = 401;
      } else {
        req.response.headers.contentType = ContentType('image', 'png');
        req.response.add(kPng);
      }
      await req.response.close();
    });
  }

  final HttpServer _server;
  final List<String> paths = [];
  final List<String?> authHeaders = [];

  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}');
  Future<void> close() => _server.close(force: true);

  static Future<_FakeMediaServer> start() async =>
      _FakeMediaServer(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
}

void main() {
  group('MediaEndpoint', () {
    test('builds the blob URL from a paired host/port', () {
      const ep = MediaEndpoint(
        base: 'https://100.64.0.1:9787',
        bearer: 'tok',
        fingerprint: 'ab12',
      );
      expect(ep.urlFor('a' * 64).toString(), 'https://100.64.0.1:9787/media/${'a' * 64}');
    });

    test('refuses an id that is not a bare sha256', () {
      const ep = MediaEndpoint(base: 'https://h:1');
      // The id lands in a URL path; a traversal or query must never be spliced
      // in, so reject rather than escape.
      expect(() => ep.urlFor('../secret'), throwsArgumentError);
      expect(() => ep.urlFor(''), throwsArgumentError);
      expect(() => ep.urlFor('${'a' * 64}?x=1'), throwsArgumentError);
    });
  });

  group('httpMediaFetcher', () {
    test('fetches the bytes and sends the paired bearer', () async {
      final server = await _FakeMediaServer.start();
      addTearDown(server.close);
      final fetch = httpMediaFetcher(
        MediaEndpoint(base: server.base.toString(), bearer: 'tok-123'),
      );

      final bytes = await fetch('a' * 64);
      expect(bytes, kPng);
      expect(server.paths.single, '/media/${'a' * 64}');
      expect(server.authHeaders.single, 'Bearer tok-123');
    });

    test('omits the header when there is no bearer (loopback dev mode)', () async {
      final server = await _FakeMediaServer.start();
      addTearDown(server.close);
      final fetch = httpMediaFetcher(MediaEndpoint(base: server.base.toString()));

      await fetch('a' * 64);
      expect(server.authHeaders.single, isNull);
    });

    test('maps a 404 to MediaNotFoundException (a GC\'d blob, not an error)', () async {
      final server = await _FakeMediaServer.start();
      addTearDown(server.close);
      final fetch = httpMediaFetcher(MediaEndpoint(base: server.base.toString()));

      await expectLater(
        fetch(kGoneId),
        throwsA(isA<MediaNotFoundException>()),
      );
    });

    test('maps any other failure to MediaFetchException', () async {
      final server = await _FakeMediaServer.start();
      addTearDown(server.close);
      final fetch = httpMediaFetcher(MediaEndpoint(base: server.base.toString()));

      await expectLater(
        fetch(kDeniedId),
        throwsA(isA<MediaFetchException>()),
      );
      // An unreachable server must fail, not hang forever.
      final dead = httpMediaFetcher(
        const MediaEndpoint(base: 'http://127.0.0.1:1'),
      );
      await expectLater(dead('a' * 64), throwsA(isA<MediaFetchException>()));
    });
  });
}
